
# PostgreSQL Service
resource "aiven_pg" "postgres-service" {

  project      = var.aiven_project_name
  cloud_name   = var.aiven_cloud
  plan         = var.pg_plan
  service_name = "${var.service_prefix}-pg"
}

# Kafka Service
resource "aiven_kafka" "kafka-service" {
  project                 = var.aiven_project_name
  cloud_name              = var.aiven_cloud
  plan                    = var.kafka_plan
  service_name            = "${var.service_prefix}-kafka"
  maintenance_window_dow  = "monday"
  maintenance_window_time = "10:00:00"

  kafka_user_config {
    kafka_connect   = false
    kafka_rest      = true
    schema_registry = false
    kafka {
      auto_create_topics_enable    = true
    }
  }
}

# Apache Flink service
resource "aiven_flink" "flink" {
  project                 = var.aiven_project_name
  cloud_name              = var.aiven_cloud
  plan                    = "business-4"
  service_name            = "${var.service_prefix}-flink"
  maintenance_window_dow  = "monday"
  maintenance_window_time = "10:00:00"

  flink_user_config {
    flink_version = 1.16
  }
}

# Flink Integration
resource "aiven_service_integration" "flink_integration_kafka" {
    project = var.aiven_project_name
    integration_type = "flink"
    source_service_name = aiven_kafka.kafka-service.service_name
    destination_service_name = aiven_flink.flink.service_name
    depends_on = [ aiven_flink.flink, aiven_kafka.kafka-service ]

}
# Flink Integration
resource "aiven_service_integration" "flink_integratio_pg" {
    project = var.aiven_project_name
    integration_type = "flink"
    source_service_name = aiven_pg.postgres-service.service_name
    destination_service_name = aiven_flink.flink.service_name
    depends_on = [ aiven_flink.flink, aiven_pg.postgres-service ]
}



resource "local_sensitive_file" "env" {
    content = <<EOF
PROJECT_NAME="${var.aiven_project_name}"
SERVICE_NAME="${aiven_kafka.kafka-service.service_name}"
TOPIC="${var.kafka_topic}"
PARTITIONS=2
REPLICATION=2
NR_MESSAGES=0
MAX_TIME=0
SUBJECT="metric"
USERNAME="${var.aiven_user_email}"
TOKEN="${var.aiven_api_token}"
PRIVATELINK="NO"
SECURITY="SSL"
EOF
filename = "${abspath(path.module)}/../data-producer/conf/env.conf"
file_permission = 0744 

}

resource "null_resource" "load_pg_data" {
    depends_on = [ aiven_pg.postgres-service ]

    provisioner "local-exec" {
        command = "psql ${aiven_pg.postgres-service.service_uri} -f ${abspath(path.module)}/../data/create.sql "
    }
}