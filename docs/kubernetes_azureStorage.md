
# Prerequisits

* az cli 
* docker
* kubectl
* access to azure subscription with Contributor or Owner role


# Create resource group in azure

```bash
az group create --name geni-azure-demo --location westeurope
```

# Create Azure Container Registry 

```bash
az acr create --resource-group geni-azure-demo --name genidemo18w --sku Basic
```

# Create Azure Kubernetes Cluster

```bash
az aks create --resource-group geni-azure-demo --name geniCluster --node-count 3  --generate-ssh-keys --attach-acr genidemo18w
```

# install Kubernetes credentials into kubectl

```bash
az aks get-credentials --resource-group geni-azure-demo --name geniCluster
```


# Create storage account to hold data to analyse

```bash
# Change these four parameters as needed for your own environment
export AKS_PERS_STORAGE_ACCOUNT_NAME=genistorageaccount$RANDOM
export AKS_PERS_RESOURCE_GROUP=geni-azure-demo
export AKS_PERS_LOCATION=westeurope
export AKS_PERS_SHARE_NAME=aksshare


# Create a storage account
az storage account create -n $AKS_PERS_STORAGE_ACCOUNT_NAME -g $AKS_PERS_RESOURCE_GROUP -l $AKS_PERS_LOCATION --sku Standard_LRS

# Export the connection string as an environment variable, this is used when creating the Azure file share
export AZURE_STORAGE_CONNECTION_STRING=$(az storage account show-connection-string -n $AKS_PERS_STORAGE_ACCOUNT_NAME -g $AKS_PERS_RESOURCE_GROUP -o tsv)

# Create the file share
az storage share create -n $AKS_PERS_SHARE_NAME --connection-string $AZURE_STORAGE_CONNECTION_STRING

# Get storage account key
export STORAGE_KEY=$(az storage account keys list --resource-group $AKS_PERS_RESOURCE_GROUP --account-name $AKS_PERS_STORAGE_ACCOUNT_NAME --query "[0].value" -o tsv)

# Echo storage account name and key
echo Storage account name: $AKS_PERS_STORAGE_ACCOUNT_NAME
echo Storage account key: $STORAGE_KEY

```

# Create persistent volume claim in Kubernetes
## create namespace and service account in kubernetes

```bash
kubectl create namespace spark
kubectl create serviceaccount spark-serviceaccount --namespace spark
kubectl create clusterrolebinding spark-rolebinding --clusterrole=edit --serviceaccount=spark:spark-serviceaccount --namespace=spark

```

## Create secret to access storage

```bash
kubectl create secret generic azure-secret --from-literal=azurestorageaccountname=$AKS_PERS_STORAGE_ACCOUNT_NAME --from-literal=azurestorageaccountkey=$STORAGE_KEY -n spark
```

Create file pvc.yaml with content:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: azurefile
  namespace: spark
spec:
  capacity:
    storage: 50Gi
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
      storage: 50Gi
```

```bash
kubectl create -f pvc.yaml
```


# Prepare Spark driver pod 
## Create Docker image for driver

```Dockerfile
FROM clojure:latest
RUN apt-get update && apt-get install -y wget
RUN printf  '{:deps {zero.one/geni {:mvn/version "0.0.31"}  \n\
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
CMD  ["clj", "-R:nREPL",  "-m",  "nrepl.cmdline" , "--middleware", "[cider.nrepl/cider-middleware,refactor-nrepl.middleware/wrap-refactor]" ,"-p", "12345", "-h", "0.0.0.0" ]
```

## build driver image

```bash
docker build -t genidemo18w.azurecr.io/geni .
```

Push image to registry

```bash
az acr login --name genidemo18w
docker push genidemo18w.azurecr.io/geni
```

## Create headless service for Spark driver

write to headless.yaml

```yaml

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
      port: 77777
```

```bash
kubectl create -f headless.yaml
```

## Start Spark driver pod

write into driver.yaml

```yaml
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
    image: genidemo18w.azurecr.io/geni
    volumeMounts:
        - mountPath: "/data"
          name: data-storage
  serviceAccountName: spark-serviceaccount
  restartPolicy: Never
```

# start driver and which launes a nrepl on port 12345

This starts as well the web gui of Spark on port 4040

```bash
kubectl create -f driver.yaml
```

# Prepare Spark worker pods

## Install spark distribution

Running spark on Kubernetes requires to create Docker images for the nodes.

The Spark distribution contains tools to ease the creation of suitable Docker images,
so we need to download it first.

```bash
wget https://downloads.apache.org/spark/spark-3.0.1/spark-3.0.1-bin-hadoop2.7.tgz
tar xzf spark-3.0.1-bin-hadoop2.7.tgz
cd spark-3.0.1-bin-hadoop2.7/
```

## Build images for workers

```bash

bin/docker-image-tool.sh -r genidemo18w.azurecr.io -t v3.0.1 build
```

## Push images for worker into registry

```bash
bin/docker-image-tool.sh -r genidemo18w.azurecr.io -t v3.0.1 push
```

# Copy data into storage

```bash
kubectl exec -ti geni -n spark -- wget https://data.cityofnewyork.us/Transportation/2018-Yellow-Taxi-Trip-Data/t29m-gskq -O /data/nyc_taxi.csv

```

Its 10 GB, takes a while

All bash commands so far have been integrated in a single bash [script](azureSetup/setupKubernetes.sh), which can
be run i one go. It has some variables at the start which you might want to edit.
Some of the values are refred to in teh later Clojure code, so the need to match.


# Connect to nrepl
## forward nrepl port to local machine

In a new shell:


```bash
kubectl port-forward pod/geni 12345:12345 -n spark

```

Connect to the forwarded repl connection at localhost:12345 with Emacs/cider
....
.....




Exceute the following code in Repl, this will trigger the spawning of the executor pods inside
Kubernetes

```clojure
(require '[zero-one.geni.core :as g])

;; This should be the first function executed in the repl.

(g/create-spark-session
 {:app-name "my-app"
  :log-level "INFO" ;; default is WARN
  :configs
  {:spark.master "k8s://https://kubernetes.default.svc" 
   :spark.kubernetes.container.image "genidemo18w.azurecr.io/spark:v3.0.1" 
   :spark.kubernetes.namespace "spark"
   :spark.kubernetes.authenticate.serviceAccountName "spark-serviceaccount" ;; created above
   :spark.executor.instances 2
   :spark.driver.host "headless-geni-service.spark"
   :spark.driver.port  46378   
   :spark.kubernetes.executor.volumes.persistentVolumeClaim.azurefile.mount.path  "/data"
   :spark.kubernetes.executor.volumes.persistentVolumeClaim.azurefile.options.claimName "azurefile"
   }})


```

The executors will be stopped, when the Clojure Repl is closed


# access Spark web ui
In an other bash shell

```bash
kubectl port-forward pod/geni -n spark 4040:4040
```

Access Spark web gui at http://localhost:4040

## start analysis

```clojure
(def df (g/read-csv! "/data/nyc_taxi.csv" {:inferSchema false :kebab-columns true}))
(g/print-schema df)
root
 |-- vendor-id: string (nullable = true)
 |-- tpep-pickup-datetime: string (nullable = true)
 |-- tpep-dropoff-datetime: string (nullable = true)
 |-- passenger-count: string (nullable = true)
 |-- trip-distance: string (nullable = true)
 |-- ratecode-id: string (nullable = true)
 |-- store-and-fwd-flag: string (nullable = true)
 |-- pu-location-id: string (nullable = true)
 |-- do-location-id: string (nullable = true)
 |-- payment-type: string (nullable = true)
 |-- fare-amount: string (nullable = true)
 |-- extra: string (nullable = true)
 |-- mta-tax: string (nullable = true)
 |-- tip-amount: string (nullable = true)
 |-- tolls-amount: string (nullable = true)
 |-- improvement-surcharge: string (nullable = true)
 |-- total-amount: string (nullable = true)

 ```


```clojure

(def df (g/read-csv! "/data/nyc_taxi.csv" 
  {:kebab-columns true
   :schema (g/struct-type 
    (g/struct-field :amount :long true)
    (g/struct-field :tip-amount :long true)
    (g/struct-field :tools-amount :long true)
    (g/struct-field :payment-type :string true))

    }))

(g/cache df)

(-> df
    (g/agg  (g/sum  :amount))
    g/show)

(-> df
    (g/group-by :payment-type )
    (g/sum  :amount) g/show)

```

# Cleanup
This removes everything, so there will be no further charges on Azure.

```bash
az group delete -n geni-azure-demo
```
