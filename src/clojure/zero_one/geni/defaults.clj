(ns zero-one.geni.defaults
  (:require
   [zero-one.geni.spark]))

(def spark
  "The default SparkSession as a Delayed object."
  (atom
   (zero-one.geni.spark/create-spark-session {})))
