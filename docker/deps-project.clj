(defproject geni-uberjar-example "0.0.1-SNAPSHOT"

  :source-paths           []
  :resource-paths         []
  :main                   user
  :aot                    [user]
  :jar-name               "geni-uberjar-example-%s.jar"
  :plugins                [[lein-tools-deps "0.4.5"]]
  :middleware             [lein-tools-deps.plugin/resolve-dependencies-with-deps-edn]
  :lein-tools-deps/config {:config-files [:install :project]})
