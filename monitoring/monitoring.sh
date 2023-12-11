#!/bin/bash

declare -A instanceEndpoints
declare -A instanceZones
declare -A replicationLag

heartbeatLatency=""
writerUp=0
previousWriter=""
currentWriter=""
heartbeatIssue=0
lagIssue=0

# Text settings
CLEAR="\e[0m"
BOLD="\e[1m"
UNDERLINE="\e[4m"

# Text colors
RED="\e[31m"
GREEN="\e[32m"

function setEnv
{
	echo -e "${BOLD}## Setting up the environment${CLEAR}"

	local instanceMeta
	local clusterIdentifier="auroralab-pg-cluster"

	echo -e "${BOLD}-- Describing cluster topology${CLEAR}"

        export AWSREGION=`aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]'`
        export CLUSTERENDP=`aws rds describe-db-clusters --region $AWSREGION --query "DBClusters[?starts_with(DBClusterIdentifier, '${clusterIdentifier}')].Endpoint" --output text`

	echo "---- Cluster identifier: ${clusterIdentifier}"

	readarray -t instanceNames < <(aws rds describe-db-clusters --query "DBClusters[?starts_with(DBClusterIdentifier, '${clusterIdentifier}')].DBClusterMembers" --output json | jq '.[][].DBInstanceIdentifier' | tr -d '"' | sort)

	echo "---- Cluster writer endpoint: ${CLUSTERENDP}"

	echo -e "${BOLD}-- Retrieving instance metadata${CLEAR}"

	for i in ${instanceNames[@]}; do

		instanceMeta=`aws rds describe-db-instances --db-instance-identifier "${i}" --output json`

		instanceEndpoints[$i]=`echo ${instanceMeta} | jq '.[][].Endpoint.Address' | tr -d '"'`
		instanceZones[$i]=`echo ${instanceMeta} | jq '.[][].AvailabilityZone' | tr -d '"'`

	done

	for i in ${instanceNames[@]}; do

		echo "---- Instance '${i}' in Availability Zone '${instanceZones[$i]}'"

	done

	echo -e "${BOLD}-- Retrieving credentials from Secrets Manager${CLEAR}"

	export SECRETARN=`aws secretsmanager list-secrets --query "SecretList[?starts_with(Name, 'secretClusterAdminUser')].ARN"  --region $AWSREGION --output text`
        export CREDS=`aws secretsmanager get-secret-value --secret-id $SECRETARN --region $AWSREGION | jq -r '.SecretString'`
        export DBUSER="`echo $CREDS | jq -r '.username'`"
        export DBPASS="`echo $CREDS | jq -r '.password'`"
        export PGPASSWORD="$DBPASS"
        export PGUSER="$DBUSER"
        export PGDATABASE=postgres
        export PGHOST="$CLUSTERENDP"

	echo "---- Database user: ${PGUSER}"

	echo -e "${BOLD}-- Preparing heartbeat table${CLEAR}"

	export PGCONNECT_TIMEOUT=2

        psql -h ${PGHOST} -c "create table if not exists heartbeat (n SERIAL PRIMARY KEY, insert_time TIMESTAMP DEFAULT current_timestamp);" -c "truncate table heartbeat;" > /dev/null 2>&1

}

function instanceStatus
{

	local instanceName
	local instanceRole
	local lagInfo
	local heartbeatInfo

	echo ""

	writerUp=0

	heartbeatIssue=0
	lagIssue=0

	for instanceName in ${instanceNames[@]}; do

		instanceRole=`psql -t -h ${instanceEndpoints[${instanceName}]} -c "select case when 'MASTER_SESSION_ID' = session_id then 'writer' else 'reader' end as instance_role from aurora_replica_status() where server_id = aurora_db_instance_identifier();"  2>/dev/null | tr -d " "`

		echo -n " ${instanceName} is "

		if [ -z "$instanceRole" ]; then

			echo -e "${RED}offline${CLEAR}"

		else

			if [ $instanceRole = "writer" ]; then

				writerUp=1
			
				if [ "$instanceName" != "$currentWriter" ]; then

					if [ -z "$currentWriter" ]; then
						previousWriter=$instanceName
					else
						previousWriter=$currentWriter
					fi

					currentWriter=$instanceName

				else
					previousWriter=$currentWriter
				fi

				if [ -z "$heartbeatLatency" ]; then
					heartbeatInfo=", waiting for heartbeat data"
				else
					if [ `echo $heartbeatLatency |cut -d'.' -f1` -gt 10 ]; then
						heartbeatIssue=1
						heartbeatInfo=", heartbeat latency ${RED}${heartbeatLatency}${CLEAR} ms"
					else
						heartbeatInfo=", heartbeat latency ${heartbeatLatency} ms"
					fi
				fi

				echo -e "${GREEN}online${CLEAR} as writer in ${instanceZones[$instanceName]}${heartbeatInfo}"

			else

				if [ -z "${replicationLag[$instanceName]}" ]; then
					lagInfo=", waiting for replication lag data"
				else
					if [ ${replicationLag[$instanceName]} -gt 1000 ]; then
						lagIssue=1
						lagInfo=", replication lag ${RED}${replicationLag[$instanceName]}${CLEAR} ms"
					else
						lagInfo=", replication lag ${replicationLag[$instanceName]} ms"
					fi
				fi
	
				echo -e "${GREEN}online${CLEAR} as reader in ${instanceZones[$instanceName]}$lagInfo"

			fi
		fi

	done

}

function statusSummary 
{

	echo ""
	
	if [ $writerUp -eq 0 ]; then
		echo -e "${BOLD}${RED}!!${CLEAR} Writer instance is down"
	fi

	if [ "$currentWriter" != "$previousWriter" ]; then
		echo -e "${BOLD}${RED}!!${CLEAR} Writer moved from '${previousWriter}' (${instanceZones[$previousWriter]}) to '${currentWriter}' (${instanceZones[$currentWriter]})"
	fi

	if [ $heartbeatIssue -eq 1 ]; then
		echo -e "${BOLD}${RED}!!${CLEAR} Elevated write heartbeat latency detected"
	fi

	if [ $lagIssue -eq 1 ]; then
                echo -e "${BOLD}${RED}!!${CLEAR} Elevated replication lag detected"
        fi

}

function replicationStatus
{

	local replicationStatus
	local instanceName
	local instanceLag

	replicationStatus=`psql -A -t -h ${CLUSTERENDP} -c "select server_id as \"Instance\", replica_lag_in_msec as \"Lag (ms)\" from aurora_replica_status() where session_id <> 'MASTER_SESSION_ID';" 2>/dev/null`
	
	if [ -z "$replicationStatus" ]; then
		
		for instanceName in ${!instanceEndpoints[@]}; do
			replicationLag[${instanceName}]=""
		done

	else
		for i in $replicationStatus; do

			instanceName=`echo $i | cut -d'|' -f 1`
			instanceLag=`echo $i | cut -d'|' -f 2`
			replicationLag[${instanceName}]=$instanceLag

		done
	fi

}

function heartbeatLatency
{

	heartbeatLatency=`psql -h ${CLUSTERENDP} -c "\timing on" -c "insert into heartbeat (n, insert_time) values (default, default);" 2>/dev/null |grep Time | cut -d' ' -f2`

}

function stampHeader 
{

	stamp=`date`
	terminalWidth=`tput cols`
	fillWidth=$(((${terminalWidth}-${#stamp}-2)/2))

	echo -e "${UNDERLINE}"
	for i in `seq 1 ${terminalWidth}`; do echo -n " "; done
	echo -e "${CLEAR}"

	for i in `seq 1 ${fillWidth}`; do echo -n "-"; done
	echo -n " ${stamp} "
	for i in `seq 1 ${fillWidth}`; do echo -n "-"; done
	echo ""
}

function mainLoop
{

	local terminalWidth
	local fillWidth

	echo "## Monitoring started"
	
	while true; do

		stampHeader
		heartbeatLatency
		replicationStatus
		instanceStatus
		statusSummary

		sleep 1

	done

}

clear
setEnv
mainLoop
