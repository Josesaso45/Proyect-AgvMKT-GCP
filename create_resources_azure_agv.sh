#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Variables de Configuración ---
SUBSCRIPTION_ID="2b72c820-d3b3-4833-860a-1f16208ceabc"
AZURE_USERNAME="azureuser" # Admin username for VM and Synapse
AZURE_PASSWORD="PASSWORD_MUY_SEGURO_CAMBIAME_123!" # !! CAMBIA ESTO y NO LO GUARDES EN GIT !! Considera Azure Key Vault o variables de entorno.

# Nomenclatura: az-<iniciales>-<diplomado>-<scope>-<topic>
INITIALS="mmj"
DIPLOMADO="do10"
TOPIC="agvmk-comi"
LOCATION="East US" # O la región que prefieras

RESOURCE_GROUP="az-${INITIALS}-${DIPLOMADO}-rg-dev-${TOPIC}"
STORAGE_ACCOUNT="az${INITIALS}${DIPLOMADO}sa${TOPIC//-}"
ADLS_FS_LANDING="landing"
ADLS_FS_BRONZE="bronze"
ADLS_FS_SILVER="silver"
ADLS_FS_GOLD="gold" # Contenedores/File Systems
DATA_FACTORY="az-${INITIALS}-${DIPLOMADO}-adf-${TOPIC}"
SYNAPSE_WORKSPACE="az-${INITIALS}-${DIPLOMADO}-synw-${TOPIC}"
SYNAPSE_DEDICATED_POOL="az-${INITIALS}-${DIPLOMADO}-syndp-${TOPIC}"
SYNAPSE_POOL_PERFORMANCE="DW100c" # El más pequeño para empezar
VM_NAME="az-${INITIALS}-${DIPLOMADO}-vm-${TOPIC}"
VM_IMAGE="Ubuntu2204"
VM_SIZE="Standard_B1ls" # Tamaño económico para empezar

# --- Ejecución ---

echo "Configurando la suscripción: $SUBSCRIPTION_ID"
az account set --subscription $SUBSCRIPTION_ID

# 1. Crear Resource Group
echo "--------------------------------------------------"
echo "Creando Resource Group: $RESOURCE_GROUP en $LOCATION"
echo "--------------------------------------------------"
az group create --name $RESOURCE_GROUP --location "$LOCATION"
echo "Resource Group $RESOURCE_GROUP creado."
echo ""

# 2. Crear Storage Account (ADLS Gen2)
echo "--------------------------------------------------"
echo "Creando Storage Account (ADLS Gen2): $STORAGE_ACCOUNT"
echo "--------------------------------------------------"
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --hns true # Habilitar Hierarchical Namespace para ADLS Gen2
echo "Storage Account $STORAGE_ACCOUNT creado."
echo "Esperando 15 segundos para la propagación..."
sleep 15 # Pequeña pausa para asegurar que la cuenta esté lista para crear contenedores
echo ""

# 3. Crear Contenedores (File Systems en ADLS Gen2)
echo "--------------------------------------------------"
echo "Creando File Systems (Contenedores) en $STORAGE_ACCOUNT"
echo "--------------------------------------------------"
# Usamos 'az storage fs create' que es específico para ADLS Gen2 con HNS
# Esto requiere que el usuario ejecutando el script tenga roles como 'Storage Blob Data Contributor'
# Alternativamente, se puede usar la clave de acceso, pero es menos seguro. Intentamos primero con RBAC.
# Si falla por permisos, descomenta la línea de STORAGE_KEY y usa --account-key en los comandos de abajo.

# STORAGE_KEY=$(az storage account keys list --resource-group $RESOURCE_GROUP --account-name $STORAGE_ACCOUNT --query "[0].value" --output tsv)

FILESYSTEMS=($ADLS_FS_LANDING $ADLS_FS_BRONZE $ADLS_FS_SILVER $ADLS_FS_GOLD)
for fs in "${FILESYSTEMS[@]}"; do
  echo "Creando File System: $fs"
  az storage fs create --name $fs --account-name $STORAGE_ACCOUNT --auth-mode login # Intenta con RBAC
  # Si falla RBAC: az storage fs create --name $fs --account-name $STORAGE_ACCOUNT --account-key $STORAGE_KEY
  if [ $? -ne 0 ]; then
    echo "Error creando File System $fs. Verifica los permisos RBAC o considera usar --account-key."
    # exit 1 # Opcional: detener el script si falla un contenedor
  else
    echo "File System $fs creado."
  fi
done
echo ""

# 4. Crear Azure Data Factory (Aunque el rol sea mínimo por ahora)
echo "--------------------------------------------------"
echo "Creando Azure Data Factory: $DATA_FACTORY"
echo "--------------------------------------------------"
az datafactory create --resource-group $RESOURCE_GROUP --location "$LOCATION" --name $DATA_FACTORY
echo "Azure Data Factory $DATA_FACTORY creado."
echo ""

# 5. Crear Azure Synapse Workspace
echo "--------------------------------------------------"
echo "Creando Azure Synapse Workspace: $SYNAPSE_WORKSPACE"
echo "--------------------------------------------------"
az synapse workspace create \
  --name $SYNAPSE_WORKSPACE \
  --resource-group $RESOURCE_GROUP \
  --storage-account $STORAGE_ACCOUNT \
  --file-system $ADLS_FS_LANDING `# O un filesystem dedicado para Synapse`\
  --sql-admin-login-user "$AZURE_USERNAME" \
  --sql-admin-login-password "$AZURE_PASSWORD" \
  --location "$LOCATION"
echo "Synapse Workspace $SYNAPSE_WORKSPACE creado."
echo "Esperando 30 segundos para la propagación del workspace..."
# Synapse puede tardar un poco más en estar listo para añadir pools
sleep 30
echo ""

# 6. Crear Azure Synapse Dedicated SQL Pool
echo "--------------------------------------------------"
echo "Creando Synapse Dedicated SQL Pool: $SYNAPSE_DEDICATED_POOL"
echo "--------------------------------------------------"
az synapse sql pool create \
  --name $SYNAPSE_DEDICATED_POOL \
  --performance-level $SYNAPSE_POOL_PERFORMANCE \
  --workspace-name $SYNAPSE_WORKSPACE \
  --resource-group $RESOURCE_GROUP
echo "Synapse Dedicated SQL Pool $SYNAPSE_DEDICATED_POOL creado."
echo ""

# 7. Crear Máquina Virtual
echo "--------------------------------------------------"
echo "Creando Máquina Virtual: $VM_NAME"
echo "--------------------------------------------------"
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name $VM_NAME \
  --image $VM_IMAGE \
  --size $VM_SIZE \
  --admin-username "$AZURE_USERNAME" \
  --generate-ssh-keys # Genera claves SSH y las guarda localmente (~/.ssh)
echo "Máquina Virtual $VM_NAME creada."
echo ""

# 8. Configurar Apagado Automático de VM
echo "--------------------------------------------------"
echo "Configurando apagado automático para $VM_NAME a las 04:00 UTC"
echo "--------------------------------------------------"
az vm auto-shutdown --resource-group $RESOURCE_GROUP --name $VM_NAME --time 0400
echo "Apagado automático configurado."
echo ""

echo "--------------------------------------------------"
echo "¡Aprovisionamiento completado!"
echo "--------------------------------------------------"
echo "Próximos pasos recomendados:"
echo "1. ¡CAMBIA LA CONTRASEÑA PREDETERMINADA ('$AZURE_PASSWORD') INMEDIATAMENTE SI LA USAS!"
echo "2. Considera usar Azure Key Vault para gestionar secretos (claves de storage, contraseñas)."
echo "3. Conéctate a la VM ($VM_NAME) usando SSH con la clave generada."
echo "4. Configura el acceso de Databricks CE a ADLS ($STORAGE_ACCOUNT)."
echo "5. Configura el conector de Databricks CE a Synapse ($SYNAPSE_DEDICATED_POOL)."