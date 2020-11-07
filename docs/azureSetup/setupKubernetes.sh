#!/bin/bash -x

set -e


export AZURE_LOCATION=westeurope
export AZURE_RESSOURCE_GROUP_NAME=geni-azure-demo
export ACR_NAME=genidemo18w
export AKS_CLUSTER_NAME=geniCluster
export AKS_NODE_COUNT=3
export AKS_VOLUME_SIZE=50Gi
export GENI_NREPL_PORT=12345
export DATA_FILE_URL=https://data.cityofnewyork.us/api/views/t29m-gskq/rows.csv?accessType=DOWNLOAD
export DATA_FILE_LOCAL_NAME=nyc_taxi.csv
export AKS_PERS_SHARE_NAME=aksshare
export AKS_PERS_STORAGE_ACCOUNT_NAME=genistorageaccount$RANDOM


az group create --name $AZURE_RESSOURCE_GROUP_NAME --location $AZURE_LOCATION
az acr create --resource-group $AZURE_RESSOURCE_GROUP_NAME  --name $ACR_NAME --sku Basic
az aks create --resource-group  $AZURE_RESSOURCE_GROUP_NAME --name $AKS_CLUSTER_NAME --node-count $AKS_NODE_COUNT  --generate-ssh-keys --attach-acr $ACR_NAME
az aks get-credentials --resource-group $AZURE_RESSOURCE_GROUP_NAME  --name $AKS_CLUSTER_NAME --overwrite-existing
az storage account create -n $AKS_PERS_STORAGE_ACCOUNT_NAME -g $AZURE_RESSOURCE_GROUP_NAME -l $AZURE_LOCATION --sku Standard_LRS

# Export the connection string as an environment variable, this is used when creating the Azure file share
export AZURE_STORAGE_CONNECTION_STRING=$(az storage account show-connection-string -n $AKS_PERS_STORAGE_ACCOUNT_NAME -g $AZURE_RESSOURCE_GROUP_NAME  -o tsv)

# Create the file share
az storage share create -n $AKS_PERS_SHARE_NAME --connection-string $AZURE_STORAGE_CONNECTION_STRING

# Get storage account key
export STORAGE_KEY=$(az storage account keys list --resource-group $AZURE_RESSOURCE_GROUP_NAME --account-name $AKS_PERS_STORAGE_ACCOUNT_NAME --query "[0].value" -o tsv)

# Echo storage account name and key
echo Storage account name: $AKS_PERS_STORAGE_ACCOUNT_NAME
echo Storage account key: $STORAGE_KEY

kubectl create namespace spark
kubectl create serviceaccount spark-serviceaccount --namespace spark
kubectl create clusterrolebinding spark-rolebinding --clusterrole=edit --serviceaccount=spark:spark-serviceaccount --namespace=spark

kubectl create secret generic azure-secret --from-literal=azurestorageaccountname=$AKS_PERS_STORAGE_ACCOUNT_NAME --from-literal=azurestorageaccountkey=$STORAGE_KEY -n spark


cat > pvc.yaml << EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: azurefile
  namespace: spark
spec:
  capacity:
    storage: $AKS_VOLUME_SIZE
  accessModes:
    - ReadWriteMany
  storageClassName: azurefile
  azureFile:
    secretName: azure-secret
    shareName: aksshare
    readOnly: false
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: azurefile
  namespace: spark
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: azurefile
  resources:
    requests:
      storage: $AKS_VOLUME_SIZE
EOF

kubectl create -f pvc.yaml


cat > Dockerfile << EOF
FROM clojure:latest
RUN apt-get update && apt-get install -y wget
RUN wget https://aka.ms/downloadazcopy-v10-linux && tar -xvf downloadazcopy-v10-linux && cp ./azcopy_linux_amd64_*/azcopy /usr/bin/
RUN printf  '{:deps {zero.one/geni {:mvn/version "0.0.34"}  \n\
                     org.apache.spark/spark-core_2.12 {:mvn/version "3.0.1" } \n\
                     org.apache.spark/spark-mllib_2.12 {:mvn/version "3.0.1"} \n\
                     org.apache.spark/spark-kubernetes_2.12 {:mvn/version  "3.0.1"}} \n\
                     :aliases {:nREPL \n\
                               {:extra-deps \n\
                                           {clj-commons/pomegranate {:mvn/version "1.2.0"} \n\
                                           nrepl/nrepl {:mvn/version "0.8.3"} \n\
                                           refactor-nrepl/refactor-nrepl {:mvn/version "2.5.0"} \n\
                                           cider/cider-nrepl {:mvn/version "0.25.3"}}}}}' >> deps.edn

RUN clj -P
CMD  ["clj", "-R:nREPL",  "-m",  "nrepl.cmdline" , "--middleware", "[cider.nrepl/cider-middleware,refactor-nrepl.middleware/wrap-refactor]" ,"-p", "$GENI_NREPL_PORT", "-h", "0.0.0.0" ]
EOF

docker build -t $ACR_NAME.azurecr.io/geni - <  Dockerfile

az acr login  --name $ACR_NAME
docker push $ACR_NAME.azurecr.io/geni




## Create headless service for Spark driver

cat > headless.yaml << EOF
apiVersion: v1
kind: Service
metadata:
  name: headless-geni-service
  namespace: spark
spec:
  clusterIP: None
  selector:
    app: geni
  ports:
    - protocol: TCP
      port: 46378
EOF

kubectl create -f headless.yaml

## Start Spark driver pod

cat > driver.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  namespace: spark
  name: geni
  labels:
    app: geni
spec:
  volumes:
    - name: data-storage
      persistentVolumeClaim:
        claimName: azurefile
  containers:
  - name: geni
    image: $ACR_NAME.azurecr.io/geni
    volumeMounts:
        - mountPath: "/data"
          name: data-storage
  serviceAccountName: spark-serviceaccount
  restartPolicy: Never
EOF

kubectl create -f driver.yaml

wget https://downloads.apache.org/spark/spark-3.0.1/spark-3.0.1-bin-hadoop2.7.tgz
tar xzf spark-3.0.1-bin-hadoop2.7.tgz
cd spark-3.0.1-bin-hadoop2.7/

bin/docker-image-tool.sh -r $ACR_NAME.azurecr.io -t v3.0.1 build
bin/docker-image-tool.sh -r $ACR_NAME.azurecr.io -t v3.0.1 push

kubectl exec -ti geni -n spark -- wget $DATA_FILE_URL -O /data/$DATA_FILE_LOCAL_NAME





#kubectl exec -tui geni -n spark

#az group delete -n geni-azure-demo
