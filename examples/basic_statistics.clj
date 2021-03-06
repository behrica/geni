(ns examples.basic-statistics
  (:require
   [clojure.pprint]
   [zero-one.geni.core :as g]
   [zero-one.geni.ml :as ml]
   [zero-one.geni.test-resources :refer [melbourne-df]]))

(def dataframe
  (-> melbourne-df
      (g/limit 3)
      (g/select
       {:location (g/map (g/lit "suburb") :Suburb
                         (g/lit "region") :Regionname
                         (g/lit "council") :CouncilArea
                         (g/lit "address") :Address)
        :market   (g/map-from-entries
                   (g/array (g/struct (g/lit "size") (g/double :Price))
                            (g/struct (g/lit "price") (g/double :Price))))
        :coord    (g/map-from-arrays
                   (g/array (g/lit "lat") (g/lit "long"))
                   (g/array :Lattitude :Longtitude))})))

(clojure.pprint/pprint (g/collect dataframe))

;;=>
;; ({:location
;;   {"suburb" "Abbotsford",
;;    "region" "Northern Metropolitan",
;;    "council" "Yarra",
;;    "address" "85 Turner St"},
;;   :market {"size" 1480000.0, "price" 1480000.0},
;;   :coord {"lat" -37.7996, "long" 144.9984}}
;;  {:location
;;   {"suburb" "Abbotsford",
;;    "region" "Northern Metropolitan",
;;    "council" "Yarra",
;;    "address" "25 Bloomburg St"},
;;   :market {"size" 1035000.0, "price" 1035000.0},
;;   :coord {"lat" -37.8079, "long" 144.9934}}
;;  {:location
;;   {"suburb" "Abbotsford",
;;    "region" "Northern Metropolitan",
;;    "council" "Yarra",
;;    "address" "5 Charles St"},
;;   :market {"size" 1465000.0, "price" 1465000.0},
;;   :coord {"lat" -37.8093, "long" 144.9944}})

(g/print-schema melbourne-df)

;;=>
;; root
;; |-- Suburb: string (nullable = true)
;; |-- Address: string (nullable = true)
;; |-- Rooms: long (nullable = true)
;; |-- Type: string (nullable = true)
;; |-- Price: double (nullable = true)
;; |-- Method: string (nullable = true)
;; |-- SellerG: string (nullable = true)
;; |-- Date: string (nullable = true)
;; |-- Distance: double (nullable = true)
;; |-- Postcode: double (nullable = true)
;; |-- Bedroom2: double (nullable = true)
;; |-- Bathroom: double (nullable = true)
;; |-- Car: double (nullable = true)
;; |-- Landsize: double (nullable = true)
;; |-- BuildingArea: double (nullable = true)
;; |-- YearBuilt: double (nullable = true)
;; |-- CouncilArea: string (nullable = true)
;; |-- Lattitude: double (nullable = true)
;; |-- Longtitude: double (nullable = true)
;; |-- Regionname: string (nullable = true)
;; |-- Propertycount: double (nullable = true)

;; Correlation
(def corr-df
  (g/table->dataset
   [[(g/dense 1.0 0.0 -2.0 0.0)]
    [(g/dense 4.0 5.0 0.0  3.0)]
    [(g/dense 6.0 7.0 0.0  8.0)]
    [(g/dense 9.0 0.0 1.0  0.0)]]
   [:features]))

(let [corr-kw (keyword "pearson(features)")]
  (corr-kw (g/first (ml/corr corr-df "features"))))

;; => ((1.0                  0.055641488407465814 0.9442673704375603  0.1311482458941057)
;;     (0.055641488407465814 1.0                  0.22329687826943603 0.9428090415820635)
;;     (0.9442673704375603   0.22329687826943603  1.0                 0.19298245614035084)
;;     (0.1311482458941057   0.9428090415820635   0.19298245614035084 1.0))

;; Hypothesis Testing
(def hypothesis-df
  (g/table->dataset
   [[0.0 (g/dense 0.5 10.0)]
    [0.0 (g/dense 1.5 20.0)]
    [1.0 (g/dense 1.5 30.0)]
    [0.0 (g/dense 3.5 30.0)]
    [0.0 (g/dense 3.5 40.0)]
    [1.0 (g/dense 3.5 40.0)]]
   [:label :features]))

(g/first (ml/chi-square-test hypothesis-df "features" "label"))

;; => {:pValues (0.6872892787909721 0.6822703303362126),
;;     :degreesOfFreedom (2 3),
;;     :statistics (0.75 1.5))
