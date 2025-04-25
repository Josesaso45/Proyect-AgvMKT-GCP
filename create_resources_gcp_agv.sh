#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Variables de Configuración ---
# !!! IMPORTANTE: Configura tu PROJECT_ID aquí !!!
PROJECT_ID="TU_PROJECT_ID_DE_GCP" # Reemplaza esto con tu ID de proyecto real

# Nomenclatura y Variables
INITIALS="mmj"
DIPLOMADO="do10"
TOPIC="agrovet-comisiones"
REGION="us-central1" # Elige la región GCP más cercana o adecuada
ZONE="${REGION}-a" # Elige una zona dentro de la región

GCS_BUCKET_RAW="gcp-${INITIALS}-${DIPLOMADO}-raw-${TOPIC}-${PROJECT_ID}" # Bucket names must be globally unique, adding PROJECT_ID helps
BQ_DATASET_STAGE="stage_${TOPIC//-/_}" # BigQuery datasets are project-specific, simpler name ok. Replace '-' with '_'
BQ_DATASET_REPORTING="reporting_${TOPIC//-/_}" # Replace '-' with '_'
VM_NAME="gcp-${INITIALS}-${DIPLOMADO}-vm-${TOPIC}"
VM_MACHINE_TYPE="e2-micro" # Tipo de máquina económico para empezar
VM_IMAGE_PROJECT="ubuntu-os-cloud"
VM_IMAGE_FAMILY="ubuntu-2204-lts"
SERVICE_ACCOUNT_NAME="sa-${INITIALS}-${DIPLOMADO}-${TOPIC}" # Nombre corto para Service Account
SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# --- Ejecución ---

echo "Configurando el proyecto por defecto: $PROJECT_ID"
gcloud config set project $PROJECT_ID

# 1. Habilitar APIs necesarias
echo "--------------------------------------------------"
echo "Habilitando APIs necesarias (Compute, Storage, BigQuery)..."
echo "--------------------------------------------------"
gcloud services enable compute.googleapis.com \
                       storage.googleapis.com \
                       bigquery.googleapis.com \
                       iam.googleapis.com # Necesaria para crear Service Account
echo "APIs habilitadas."
echo ""

# 2. Crear GCS Bucket para Capa Raw
echo "--------------------------------------------------"
echo "Creando GCS Bucket (Raw): gs://$GCS_BUCKET_RAW"
echo "--------------------------------------------------"
# Verificar si el bucket ya existe antes de intentar crearlo
if ! gcloud storage buckets describe "gs://$GCS_BUCKET_RAW" --quiet > /dev/null 2>&1; then
  gcloud storage buckets create "gs://$GCS_BUCKET_RAW" --project=$PROJECT_ID --location=$REGION --uniform-bucket-level-access
  echo "GCS Bucket gs://$GCS_BUCKET_RAW creado."
else
  echo "GCS Bucket gs://$GCS_BUCKET_RAW ya existe."
fi
echo ""

# 3. Crear BigQuery Datasets
echo "--------------------------------------------------"
echo "Creando BigQuery Datasets: $BQ_DATASET_STAGE y $BQ_DATASET_REPORTING"
echo "--------------------------------------------------"
# Verificar y crear dataset Stage
if ! bq --project_id=$PROJECT_ID show --format=prettyjson "$PROJECT_ID:$BQ_DATASET_STAGE" > /dev/null 2>&1; then
  bq --location=$REGION mk --dataset --description "Dataset para datos en etapa de Staging - ${TOPIC}" $PROJECT_ID:$BQ_DATASET_STAGE
  echo "BigQuery Dataset $BQ_DATASET_STAGE creado."
else
  echo "BigQuery Dataset $BQ_DATASET_STAGE ya existe."
fi
# Verificar y crear dataset Reporting
if ! bq --project_id=$PROJECT_ID show --format=prettyjson "$PROJECT_ID:$BQ_DATASET_REPORTING" > /dev/null 2>&1; then
  bq --location=$REGION mk --dataset --description "Dataset para datos listos para Reporting - ${TOPIC}" $PROJECT_ID:$BQ_DATASET_REPORTING
  echo "BigQuery Dataset $BQ_DATASET_REPORTING creado."
else
  echo "BigQuery Dataset $BQ_DATASET_REPORTING ya existe."
fi
echo ""

# 4. Crear Service Account para la VM (Buenas Prácticas IAM)
echo "--------------------------------------------------"
echo "Creando Service Account: $SERVICE_ACCOUNT_NAME"
echo "--------------------------------------------------"
if ! gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" --project=$PROJECT_ID > /dev/null 2>&1; then
  gcloud iam service-accounts create $SERVICE_ACCOUNT_NAME \
    --description="Service Account para la VM del proyecto ${TOPIC}" \
    --display-name="SA VM ${TOPIC}" \
    --project=$PROJECT_ID
  echo "Service Account $SERVICE_ACCOUNT_EMAIL creada."
  # Otorgar roles mínimos necesarios (Ajusta según necesidad)
  echo "Otorgando roles a Service Account..."
  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
    --role="roles/storage.objectAdmin" # Permisos para leer/escribir en GCS
  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
    --role="roles/bigquery.dataEditor" # Permisos para leer/escribir datos en BQ
  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
    --role="roles/bigquery.jobUser" # Permisos para ejecutar jobs en BQ
else
  echo "Service Account $SERVICE_ACCOUNT_EMAIL ya existe."
fi
echo ""

# 5. Crear Máquina Virtual (GCE)
echo "--------------------------------------------------"
echo "Creando Máquina Virtual (GCE): $VM_NAME"
echo "--------------------------------------------------"
if ! gcloud compute instances describe $VM_NAME --zone=$ZONE --project=$PROJECT_ID > /dev/null 2>&1; then
  gcloud compute instances create $VM_NAME \
    --project=$PROJECT_ID \
    --zone=$ZONE \
    --machine-type=$VM_MACHINE_TYPE \
    --image-project=$VM_IMAGE_PROJECT \
    --image-family=$VM_IMAGE_FAMILY \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --service-account=$SERVICE_ACCOUNT_EMAIL # Asignar la SA creada a la VM
  echo "Máquina Virtual $VM_NAME creada."
else
  echo "Máquina Virtual $VM_NAME ya existe."
fi
echo ""

# Nota: El auto-apagado en GCP no es un flag directo como en Azure.
# Se puede lograr con Cloud Scheduler + Cloud Functions/PubSub o scripts de startup/shutdown.
# Por la urgencia de hoy, lo omitimos del aprovisionamiento inicial.

echo "--------------------------------------------------"
echo "¡Aprovisionamiento en GCP completado!"
echo "--------------------------------------------------"
echo "Próximos pasos recomendados:"
echo "1. Guarda este script y todo tu código en un repositorio GIT."
echo "2. Conéctate a la VM ($VM_NAME) usando 'gcloud compute ssh $VM_NAME --zone $ZONE'."
echo "3. Clona tu repositorio Git en la VM."
echo "4. Prepara tus archivos CSV."
echo "5. Usa 'gcloud storage cp TUS_ARCHIVOS.csv gs://$GCS_BUCKET_RAW/' desde la VM o tu local para subir los datos a la capa Raw."
echo "6. Ve a la consola de BigQuery y empieza a escribir SQL para cargar de GCS a Stage ('$BQ_DATASET_STAGE') y transformar a Reporting ('$BQ_DATASET_REPORTING')."
echo "7. Conecta Looker Studio a tus tablas de Reporting en BigQuery."