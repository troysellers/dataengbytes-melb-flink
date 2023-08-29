#!/bin/bash

cd data-producer

docker build -t fake-data-producer-for-apache-kafka-docker .

docker run fake-data-producer-for-apache-kafka-docker