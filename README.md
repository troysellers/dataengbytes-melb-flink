# DataEngBytes - Anomaly Detection using Flink

This is a repostory that supports the presentation I gave at the [DataEngBytes](https://dataengconf.com.au/session/499225?apiUrl=https://sessionize.com/api/v2/2gv8oeqy/view/All) conference in Melbourne.

This repository is a list of resources that was enumerated in the slides, with a small terraform script for those who don't feel like clicking the buttons. 

## Resources
The conference talk was built using 
* Apache Flink [documentation](https://nightlies.apache.org/flink/flink-docs-stable/)
* Aiven for Apache Flink [documentation](https://docs.aiven.io/docs/products/flink)
* Aiven Flink anomaly detection [tutorial](https://docs.aiven.io/docs/tutorials/anomaly-detection)
* Aiven Terraform [provider](https://registry.terraform.io/providers/aiven/aiven/latest/docs) 

## To Build
* Create yourself an [Aiven account](https://console.aiven.io/signup?credit_code=debmelb-23). Free trials are available
* Create the [authentication token](https://console.aiven.io/signup?credit_code=debmelb-23) 
* Run the [terraform script](#terraform)
* Build and run the [data generator](https://console.aiven.io/signup?credit_code=debmelb-23)
````
> docker build -t fake-data-producer-for-apache-kafka-docker .

> docker run fake-data-producer-for-apache-kafka-docker
```


## Terraform
The terraform script will build the three Aiven services required for the demo. 

This was built and tested with
```
> terraform version
Terraform v1.5.0
on darwin_arm64

```

Clone this repository and go to the terraform directory
```
> cd terraform
```

Initialise 
```
> terraform init
```

Plan
```
> terraform plan
```

If you like what you see, go ahead and deploy
```
> terraform deploy
```
