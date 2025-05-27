#!/bin/bash
# -------------------------------------------------------------------------------------
# Copyright (c) 2025 WSO2 LLC. (http://www.wso2.org) All Rights Reserved.
#
# WSO2 LLC. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# --------------------------------------------------------------------------------------
set -e

# === Configuration ===
JDK_TYPE=$1
INFRA_JSON=$2
WORKSPACE=/opt/testgrid/workspace
APIM_VERSION="4.5.0"
SOURCE_VERSION="3.2.0"
APIM_HOME="${WORKSPACE}/wso2am-${APIM_VERSION}"
IS_MIGRATION_LOG_FILE="$APIM_HOME/repository/logs/is-migration.log"
APIM_MIGRATION_LOG_FILE="$APIM_HOME/repository/logs/apim-migration.log"
CONFIG_FILE="${APIM_HOME}/repository/conf/deployment.toml"

function install_jdk() {
    if [ -z "$JAVA_HOME" ]; then
        jdk_name=$1

        mkdir -p /opt/${jdk_name}
        jdk_file=$(jq -r --arg name "$jdk_name" '.jdk[] | select(.name == $name) | .file_name' "${INFRA_JSON}")
        
        wget -q "https://integration-testgrid-resources.s3.amazonaws.com/lib/jdk/${jdk_file}.tar.gz"
        tar -xzf "${jdk_file}.tar.gz" -C /opt/${jdk_name} --strip-components=1

        export JAVA_HOME=/opt/${jdk_name}
        export PATH=$JAVA_HOME/bin:$PATH
        echo "JAVA_HOME set to $JAVA_HOME"
    else
        echo "JAVA_HOME is already set to $JAVA_HOME. Skipping JDK installation."
    fi
}
install_jdk ${JDK_TYPE}

# S3 base path
S3_BASE_PATH="s3://integration-testgrid-resources/apim-migration-resources/migrate-to-latest"

# Get the latest WSO2 AM migration client
wso2am_file=$(aws s3 ls ${S3_BASE_PATH}/ | awk '{print $4}' | grep '^wso2am-migration-.*\.zip$' | sort -V | tail -n1)

# Get the latest WSO2 IS migration client
wso2is_file=$(aws s3 ls ${S3_BASE_PATH}/ | awk '{print $4}' | grep '^wso2is-migration-.*\.zip$' | sort -V | tail -n1)

# Print what files will be downloaded
echo "Latest WSO2 AM Migration Client: $wso2am_file"
echo "Latest WSO2 IS Migration Client: $wso2is_file"

# Copy files from S3
aws s3 cp "${S3_BASE_PATH}/${wso2am_file}" .
aws s3 cp "${S3_BASE_PATH}/${wso2is_file}" .

unzip -q -o "${WORKSPACE}/${wso2am_file}" -d "$WORKSPACE"
unzip -q -o "${WORKSPACE}/${wso2is_file}" -d "$WORKSPACE"

APIM_MIGRATION_RESOURCES_DIR="${wso2am_file%.zip}"
IS_MIGRATION_RESOURCES_DIR="${wso2is_file%.zip}"

echo "Replace the deployment.toml file..."
wget "https://raw.githubusercontent.com/dakshina99/apim-test-integration/refs/heads/cucumber-test/apim-migration/deployment.toml"
cp deployment.toml "$APIM_HOME/repository/conf/"

echo "Replace the migration-config.yaml file..."
wget "https://raw.githubusercontent.com/dakshina99/apim-test-integration/refs/heads/cucumber-test/apim-migration/migration-config.yaml"
cp migration-config.yaml "${IS_MIGRATION_RESOURCES_DIR}/migration-resources/"

echo "Copying IS migration-resources..."
cp -r "${IS_MIGRATION_RESOURCES_DIR}/migration-resources" "$APIM_HOME/"

echo "Copyin IS migration .jar files..."
cp "${IS_MIGRATION_RESOURCES_DIR}/dropins/"*.jar "$APIM_HOME/repository/components/dropins/"

echo "Starting IS migration..."
sudo chmod 755 $APIM_HOME/bin/api-manager.sh
nohup sh "$APIM_HOME/bin/api-manager.sh" -Dmigrate -Dcomponent=identity > "$IS_MIGRATION_LOG_FILE" 2>&1 &
SERVER_PID=$!

while [ ! -f "$IS_MIGRATION_LOG_FILE" ]; do sleep 2; done

START_TRIGGER="Migration Versions List........................."
END_TRIGGER="##################################  ALERT  ##################################"
IGNORE_PATTERN='SQL script not found at .*/migration-(4.1.0_to_4.2.0|4.2.0_to_4.3.0)'

analysis_started=0

tail -n0 -F "$IS_MIGRATION_LOG_FILE" | while read -r line; do
    if [[ $analysis_started -eq 0 ]]; then
        # Wait for the analysis start trigger
        if grep -qF "$START_TRIGGER" <<< "$line"; then
            analysis_started=1
        fi
        continue
    fi

    # If end trigger is found, exit successfully
    if grep -qF "$END_TRIGGER" <<< "$line"; then
        echo "Identity Component Migration completed successfully"
        break
    fi

    # Check for errors, excluding false positives
    if grep -qE 'ERROR' <<< "$line"; then
        echo "Fatal error detected during the Identity Component Migration:"
        echo "$line"
        exit 1
    fi
done

echo "Stopping server after the identity component migration..."
sh "$APIM_HOME/bin/api-manager.sh" --stop
sleep 15

echo "Cleaning up identity migration resources..."
rm -rf "${APIM_HOME}/migration-resources"
rm -f "${APIM_HOME}/repository/components/dropins/org.wso2.carbon.is.migration"*.jar

echo "Copying APIM migration-resources..."
cp -r "${APIM_MIGRATION_RESOURCES_DIR}/migration-resources" "$APIM_HOME/"

echo "Copying APIM migration .jar files..."
cp "${APIM_MIGRATION_RESOURCES_DIR}/dropins/"*.jar "$APIM_HOME/repository/components/dropins/"

echo "Starting APIM migration..."
sudo chmod 755 $APIM_HOME/bin/api-manager.sh
nohup sh "$APIM_HOME/bin/api-manager.sh" -Dmigrate -DmigrateFromVersion="$SOURCE_VERSION" > "$APIM_MIGRATION_LOG_FILE" 2>&1 &
SERVER_PID=$!

echo "Waiting for server to start..."
while [ ! -f "$APIM_MIGRATION_LOG_FILE" ]; do sleep 2; done

START_TRIGGER="Running on migration enabled mode: Stopped at ServerStartupListener completed"
END_TRIGGER="APIMMigrationClient WSO2 API-M Migration Task : Successfully completed API-M migration"
IGNORE_PATTERN='SQL script not found at .*/migration-(4.1.0_to_4.2.0|4.2.0_to_4.3.0)'

analysis_started=0

tail -n0 -F "$APIM_MIGRATION_LOG_FILE" | while read -r line; do
    if [[ $analysis_started -eq 0 ]]; then
        # Wait for the analysis start trigger
        if grep -qF "$START_TRIGGER" <<< "$line"; then
            analysis_started=1
        fi
        continue
    fi

    # If end trigger is found, exit successfully
    if grep -qF "$END_TRIGGER" <<< "$line"; then
        echo "Migration completed successfully"
        break
    fi

    # Check for errors, excluding false positives
    if grep -qE 'ERROR' <<< "$line" && \
       ! grep -qE "$IGNORE_PATTERN" <<< "$line"; then
        echo "Fatal error detected during migration:"
        echo "$line"
        exit 1
    fi
done

echo "Stopping server after the APIM migration..."
sh "$APIM_HOME/bin/api-manager.sh" --stop
sleep 15

echo "Updating indexing config for re_indexing..."
if grep -q "^\[indexing\]" "$CONFIG_FILE"; then
   sed -i.bak '/^\[indexing\]/,/^\[/{s/^indexing *=.*/re_indexing = 1/}' "$CONFIG_FILE"
   echo "Re-indexing enabled."
else
   echo "[indexing] section not found."
fi

echo "Cleaning up migration resources..."
rm -rf "${APIM_HOME}/migration-resources"
rm -f "${APIM_HOME}/repository/components/dropins/org.wso2.carbon.apimgt.migrate.client"*.jar

echo "print migration logs"
cat "$IS_MIGRATION_LOG_FILE"
echo "IS Migration Log: $IS_MIGRATION_LOG_FILE"
echo "-----------------------------------------------------------------"
echo "APIM Migration Log: $APIM_MIGRATION_LOG_FILE"
cat "$APIM_MIGRATION_LOG_FILE"
