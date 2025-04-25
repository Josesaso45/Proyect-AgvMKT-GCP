#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
#set -e

# --- Variables de Configuración ---
# !!! IMPORTANTE: Configura tu PROJECT_ID aquí !!!
PROJECT_ID="proyecto-agrovetmkt" 

# Nomenclatura y Variables
INITIALS="mmj"
DIPLOMADO="do10"
TOPIC="agrovet-comisiones"
REGION="us-central1" # Elige la región GCP más cercana o adecuada
ZONE="${REGION}-a" # Elige una zona dentro de la región

GCS_BUCKET_RAW="gcp-${INITIALS}-${DIPLOMADO}-raw-${TOPIC}-${PROJECT_ID}" # Bucket names must be globally unique
GCS_BUCKET_STAGE="gcp-${INITIALS}-${DIPLOMADO}-stage-${TOPIC}-${PROJECT_ID}" # Bucket para Delta Lake Stage
GCS_BUCKET_CODE="gcp-${INITIALS}-${DIPLOMADO}-code-${TOPIC}-${PROJECT_ID}" # Bucket para guardar scripts PySpark

BQ_DATASET_STAGE="stage_${TOPIC//-/_}" # BigQuery datasets are project-specific
BQ_DATASET_REPORTING="reporting_${TOPIC//-/_}"

VM_NAME="gcp-${INITIALS}-${DIPLOMADO}-vm-${TOPIC}"
VM_MACHINE_TYPE="e2-medium" # Un poco más grande por si clonas repo, etc.
VM_IMAGE_PROJECT="ubuntu-os-cloud"
VM_IMAGE_FAMILY="ubuntu-2204-lts"

SERVICE_ACCOUNT_NAME="sa-${INITIALS}-${DIPLOMADO}-${TOPIC}"
SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

DATAPROC_CLUSTER_NAME="dp-${INITIALS}-${DIPLOMADO}-${TOPIC}"
DATAPROC_WORKER_TYPE="e2-standard-2" # 2 vCPU, 8 GB RAM por worker
DATAPROC_NUM_WORKERS=3 # Cluster pequeño para empezar (1 master + 3 workers)

# --- Ejecución ---

echo "Configurando el proyecto por defecto: $PROJECT_ID"
gcloud config set project $PROJECT_ID

# 1. Habilitar APIs necesarias
echo "--------------------------------------------------"
echo "Habilitando APIs necesarias (Compute, Storage, BigQuery, IAM, Dataproc)..."
echo "--------------------------------------------------"
gcloud services enable compute.googleapis.com \
                       storage.googleapis.com \
                       bigquery.googleapis.com \
                       iam.googleapis.com \
                       dataproc.googleapis.com
echo "APIs habilitadas."
echo ""

# 2. Crear GCS Buckets (Raw, Stage, Code)
echo "--------------------------------------------------"
echo "Creando GCS Buckets..."
echo "--------------------------------------------------"
BUCKETS=($GCS_BUCKET_RAW $GCS_BUCKET_STAGE $GCS_BUCKET_CODE)
for bucket in "${BUCKETS[@]}"; do
  # Verificar si el bucket ya existe antes de intentar crearlo
  if ! gcloud storage buckets describe "gs://$bucket" --quiet > /dev/null 2>&1; then
    echo "Creando GCS Bucket: gs://$bucket"
    gcloud storage buckets create "gs://$bucket" --project=$PROJECT_ID --location=$REGION --uniform-bucket-level-access
    echo "GCS Bucket gs://$bucket creado."
  else
    echo "GCS Bucket gs://$bucket ya existe."
  fi
done
echo ""

# 3. Crear BigQuery Datasets (Stage, Reporting)
echo "--------------------------------------------------"
echo "Creando BigQuery Datasets: $BQ_DATASET_STAGE y $BQ_DATASET_REPORTING"
echo "--------------------------------------------------"
DATASETS=($BQ_DATASET_STAGE $BQ_DATASET_REPORTING)
DESCRIPTIONS=("Dataset para datos en etapa de Staging - ${TOPIC}" "Dataset para datos listos para Reporting - ${TOPIC}")
for i in ${!DATASETS[@]}; do
  ds=${DATASETS[$i]}
  desc=${DESCRIPTIONS[$i]}
  # Verificar y crear dataset
  if ! bq --project_id=$PROJECT_ID show --format=prettyjson "$PROJECT_ID:$ds" > /dev/null 2>&1; then
    echo "Creando BQ Dataset: $ds"
    bq --location=$REGION mk --dataset --description "$desc" $PROJECT_ID:$ds
    echo "BigQuery Dataset $ds creado."
  else
    echo "BigQuery Dataset $ds ya existe."
  fi
done
echo ""

# 4. Crear Service Account para VM y Dataproc Workers
echo "--------------------------------------------------"
echo "Creando/Verificando Service Account: $SERVICE_ACCOUNT_NAME"
echo "--------------------------------------------------"
if ! gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" --project=$PROJECT_ID > /dev/null 2>&1; then
  gcloud iam service-accounts create $SERVICE_ACCOUNT_NAME \
    --description="Service Account para VM y Dataproc - ${TOPIC}" \
    --display-name="SA VM/DP ${TOPIC}" \
    --project=$PROJECT_ID
  echo "Service Account $SERVICE_ACCOUNT_EMAIL creada."
  # Otorgar roles mínimos necesarios (Ajusta según necesidad)
  echo "Otorgando roles a Service Account (Storage Admin, BQ Editor/JobUser, Dataproc Worker)..."
  gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" --role="roles/storage.admin" # Necesita crear/borrar objetos/delta logs
  gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" --role="roles/bigquery.dataEditor"
  gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" --role="roles/bigquery.jobUser"
  gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" --role="roles/dataproc.worker" # Rol necesario para los workers del cluster
else
  echo "Service Account $SERVICE_ACCOUNT_EMAIL ya existe. Verificando roles..."
  # Asegurarse que los roles necesarios estén presentes (comandos son idempotentes)
  gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" --role="roles/storage.admin" --condition=None > /dev/null 2>&1 || true
  gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" --role="roles/bigquery.dataEditor" --condition=None > /dev/null 2>&1 || true
  gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" --role="roles/bigquery.jobUser" --condition=None > /dev/null 2>&1 || true
  gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" --role="roles/dataproc.worker" --condition=None > /dev/null 2>&1 || true
  echo "Roles verificados/añadidos."
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

# 6. Crear Cluster de Dataproc
echo "--------------------------------------------------"
echo "Creando Cluster de Dataproc: $DATAPROC_CLUSTER_NAME"
echo "--------------------------------------------------"
# Nota: Crear un cluster puede tardar unos minutos.
if ! gcloud dataproc clusters describe $DATAPROC_CLUSTER_NAME --region=$REGION --project=$PROJECT_ID > /dev/null 2>&1; then
  gcloud dataproc clusters create $DATAPROC_CLUSTER_NAME \
    --project=$PROJECT_ID \
    --region=$REGION \
    --zone=$ZONE \
    --master-machine-type=$DATAPROC_WORKER_TYPE \
    --master-boot-disk-size=50GB \
    --num-workers=$DATAPROC_NUM_WORKERS \
    --worker-machine-type=$DATAPROC_WORKER_TYPE \
    --worker-boot-disk-size=50GB \
    --image-version=2.1-ubuntu20 # O la versión de Spark/Ubuntu que prefieras
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --service-account=$SERVICE_ACCOUNT_EMAIL \
    --properties=^#^delta.pipInstall=delta-spark # Propiedad para instalar Delta Lake via pip
    # Opcional: --enable-component-gateway (para acceder a UIs de Spark/YARN)
    # Opcional: --max-idle=1h (para auto-eliminar el cluster si está inactivo)
  echo "Cluster de Dataproc $DATAPROC_CLUSTER_NAME creado."
else
  echo "Cluster de Dataproc $DATAPROC_CLUSTER_NAME ya existe."
fi
echo ""

echo "--------------------------------------------------"
echo "¡Aprovisionamiento en GCP (con Dataproc) completado!"
echo "--------------------------------------------------"
echo "Próximos pasos recomendados:"
echo "1. Guarda este script y todo tu código en tu repositorio GIT (GitHub)."
echo "2. Conéctate a la VM ($VM_NAME) usando 'gcloud compute ssh $VM_NAME --zone $ZONE'."
echo "3. Clona tu repositorio Git en la VM."
echo "4. Escribe tus scripts PySpark (raw_to_stage_delta.py, stage_delta_to_bq.py)."
echo "5. Sube los scripts PySpark a GCS ('gs://$GCS_BUCKET_CODE/')."
echo "6. Prepara y sube tus archivos CSV a GCS Raw ('gs://$GCS_BUCKET_RAW/')."
echo "7. Envía los trabajos a Dataproc:"
echo "   gcloud dataproc jobs submit pyspark gs://$GCS_BUCKET_CODE/raw_to_stage_delta.py --cluster=$DATAPROC_CLUSTER_NAME --region=$REGION --project=$PROJECT_ID -- [argumentos_si_necesitas]"
echo "   gcloud dataproc jobs submit pyspark gs://$GCS_BUCKET_CODE/stage_delta_to_bq.py --cluster=$DATAPROC_CLUSTER_NAME --region=$REGION --project=$PROJECT_ID -- [argumentos_si_necesitas]"
echo "8. Verifica los datos en GCS Stage (Delta Lake) y BigQuery Reporting."
echo "9. Conecta Looker Studio a tus tablas de Reporting en BigQuery."