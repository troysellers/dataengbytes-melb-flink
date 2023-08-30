
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
      auto_create_topics_enable = true
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
resource "aiven_service_integration" "flink_integration_pg" {
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
TOPIC="${var.kafka_topic_filtering_in}"
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



#Flink App 1
resource "aiven_flink_application" "filtering" {
    project = var.aiven_project_name
    service_name = aiven_flink.flink.service_name
    name = "filtering"
}

resource "aiven_flink_application_version" "filtering_v1" {
    project = var.aiven_project_name
    service_name = aiven_flink.flink.service_name
    application_id = aiven_flink_application.filtering.application_id
    statement = <<EOT
        INSERT INTO CPU_OUT_FILTER 
        SELECT 
            time_ltz, 
            hostname, 
            cpu, 
            usage 
        FROM CPU_IN 
        WHERE usage > 80
    EOT
    source {
        create_table = <<EOT
            CREATE TABLE CPU_IN (
                hostname STRING,
                cpu STRING,
                usage DOUBLE,
                occurred_at BIGINT,
                time_ltz AS TO_TIMESTAMP_LTZ(occurred_at, 3),
                WATERMARK FOR time_ltz AS time_ltz - INTERVAL '10' SECOND
                )
            WITH (
            'connector' = 'kafka',
            'properties.bootstrap.servers' = '',
            'topic' = '${var.kafka_topic_filtering_in}',
            'value.format' = 'json',
            'scan.startup.mode' = 'earliest-offset'
            )
        EOT
        integration_id = aiven_service_integration.flink_integration_kafka.integration_id
    }
    sink {
        create_table = <<EOT
            CREATE TABLE CPU_OUT_FILTER (
                time_ltz TIMESTAMP(3),
                hostname STRING,
                cpu STRING,
                usage DOUBLE
                )
            WITH (
            'connector' = 'kafka',
            'properties.bootstrap.servers' = '',
            'topic' = '${var.kafka_topic_filtering_out}',
            'value.format' = 'json',
            'scan.startup.mode' = 'earliest-offset'
            )
        EOT
        integration_id = aiven_service_integration.flink_integration_kafka.integration_id
    }
}

# flink job 1 application deployment
resource "aiven_flink_application_deployment" "filtering_v1_deployment" {
  application_id = aiven_flink_application.filtering.application_id
  project = var.aiven_project_name
  service_name = aiven_flink.flink.service_name
  version_id = aiven_flink_application_version.filtering_v1.application_version_id
  parallelism = 2
}

###### Flink App 2
resource "aiven_flink_application" "windowing" {
    project = var.aiven_project_name
    service_name = aiven_flink.flink.service_name
    name = "cpu_agg"
}

resource "aiven_flink_application_version" "windowing_v1" {
    project = var.aiven_project_name
    service_name = aiven_flink.flink.service_name
    application_id = aiven_flink_application.windowing.application_id
    statement = <<EOT
            INSERT INTO CPU_OUT_AGG
            SELECT 
                window_start,
                window_end, 
                hostname, 
                cpu, 
                AVG(usage), 
                MAX(usage)
            FROM 
                TABLE( TUMBLE( TABLE CPU_IN, DESCRIPTOR(time_ltz), INTERVAL '30' SECONDS))
            GROUP BY 
                window_start,
                window_end, 
                hostname, 
                cpu
        EOT
    source {
        create_table = <<EOT
            CREATE TABLE CPU_IN (
                hostname STRING,
                cpu STRING,
                usage DOUBLE,
                occurred_at BIGINT,
                time_ltz AS TO_TIMESTAMP_LTZ(occurred_at, 3),
                WATERMARK FOR time_ltz AS time_ltz - INTERVAL '10' SECOND
                )
            WITH (
            'connector' = 'kafka',
            'properties.bootstrap.servers' = '',
            'topic' = '${var.kafka_topic_filtering_in}',
            'value.format' = 'json',
            'scan.startup.mode' = 'earliest-offset'
            )
        EOT
        integration_id = aiven_service_integration.flink_integration_kafka.integration_id
    }
    sink {
        create_table = <<EOT
            CREATE TABLE CPU_OUT_AGG(
                window_start TIMESTAMP(3),
                window_end TIMESTAMP(3),
                hostname STRING,
                cpu STRING,
                usage_avg DOUBLE,
                usage_max DOUBLE
            )
            WITH (
                'connector' = 'kafka',
                'properties.bootstrap.servers' = '',
                'topic' = '${var.kafka_topic_aggregation_stats}',
                'value.format' = 'json',
                'scan.startup.mode' = 'earliest-offset'
            )
        EOT
        integration_id = aiven_service_integration.flink_integration_kafka.integration_id
    }

}

# flink job 2 application deployment
resource "aiven_flink_application_deployment" "windowing_v1_deployment" {
  application_id = aiven_flink_application.windowing.application_id
  project = var.aiven_project_name
  service_name = aiven_flink.flink.service_name
  version_id = aiven_flink_application_version.windowing_v1.application_version_id
  parallelism = 2
}


#Flink App 3
resource "aiven_flink_application" "notifications_v1" {
    project = var.aiven_project_name
    service_name = aiven_flink.flink.service_name
    name = "cpu_notification"
}

resource "aiven_flink_application_version" "notifications_v1" {
    project = var.aiven_project_name
    service_name = aiven_flink.flink.service_name
    application_id = aiven_flink_application.notifications_v1.application_id
    statement = <<EOT
        INSERT INTO CPU_ALERTS
        SELECT
            CPU.hostname,
            ' CPU: ' || cpu || 
            ' avg CPU value:' ||  TRY_CAST(usage_avg as string) || 
            ' over the threshold ' || TRY_CAST(allowed_top as string)
        FROM CPU_IN_AGG CPU INNER JOIN CPU_THRESHOLDS
            ON CPU.hostname = CPU_THRESHOLDS.hostname 
        WHERE usage_avg > allowed_top
    EOT
    source {
        create_table = <<EOT
            CREATE TABLE CPU_IN_AGG (
                window_start TIMESTAMP(3),
                window_end TIMESTAMP(3),
                hostname STRING,
                cpu STRING,
                usage_avg DOUBLE,
                usage_max DOUBLE
                )
            WITH (
            'connector' = 'kafka',
            'properties.bootstrap.servers' = '',
            'topic' = '${var.kafka_topic_aggregation_stats}',
            'value.format' = 'json',
            'scan.startup.mode' = 'earliest-offset'
            )
        EOT
        integration_id = aiven_service_integration.flink_integration_kafka.integration_id
    }
   source {
    create_table = <<EOT
        CREATE TABLE CPU_THRESHOLDS (
            hostname STRING,
            allowed_top INT,
            PRIMARY KEY (hostname) NOT ENFORCED
        )
        WITH (
            'connector' = 'jdbc',
            'url' = 'jdbc:postgresql://',
            'table-name' = 'public.cpu_thresholds'
        )
    EOT
    integration_id = aiven_service_integration.flink_integration_pg.integration_id
   } 
    sink {
        create_table = <<EOT
           create table CPU_ALERTS (
                hostname STRING,
                message STRING
            ) WITH (
                'connector' = 'kafka',
                'properties.bootstrap.servers' = '',
                'topic' = '${var.kafka_topic_cpu_alerts}',
                'value.format' = 'json',
                'scan.startup.mode' = 'earliest-offset'
            )
        EOT
        integration_id = aiven_service_integration.flink_integration_kafka.integration_id
    }
}

# flink job 3 application deployment
resource "aiven_flink_application_deployment" "notifications_deployment" {
  application_id = aiven_flink_application.notifications_v1.application_id
  project = var.aiven_project_name
  service_name = aiven_flink.flink.service_name
  version_id = aiven_flink_application_version.notifications_v1.application_version_id
  parallelism = 2
}



# observability stack - optional
resource "aiven_influxdb" "influxdb" {
  project                 = var.aiven_project_name
  cloud_name              = var.aiven_cloud
  plan                    = var.influx_plan
  service_name            = "${var.service_prefix}-influxdb"
  maintenance_window_dow  = "monday"
  maintenance_window_time = "10:00:00"

  influxdb_user_config {
    public_access {
      influxdb = false
    }
  }
}

resource "aiven_service_integration" "kafka_metrics_integration" {
  project                  = var.aiven_project_name
  integration_type         = "metrics"
  depends_on = [ aiven_kafka.kafka-service, aiven_influxdb.influxdb ]
  source_service_name      = aiven_kafka.kafka-service.service_name
  destination_service_name = aiven_influxdb.influxdb.service_name
}

resource "aiven_service_integration" "flink_metrics_integration" {
  project                  = var.aiven_project_name
  integration_type         = "metrics"
  depends_on = [ aiven_flink.flink, aiven_influxdb.influxdb ]
  source_service_name      = aiven_flink.flink.service_name
  destination_service_name = aiven_influxdb.influxdb.service_name
}

resource "aiven_service_integration" "pg_metrics_integration" {
  project                  = var.aiven_project_name
  integration_type         = "metrics"
  depends_on = [ aiven_pg.postgres-service, aiven_influxdb.influxdb ]
  source_service_name      = aiven_pg.postgres-service.service_name
  destination_service_name = aiven_influxdb.influxdb.service_name
}

resource "aiven_grafana" "grafana" {
  project                 = var.aiven_project_name
  cloud_name              = var.aiven_cloud
  plan                    = var.grafana_plan
  service_name            = "${var.service_prefix}-grafana"
  maintenance_window_dow  = "monday"
  maintenance_window_time = "10:00:00"

  grafana_user_config {
    alerting_enabled = true

    public_access {
      grafana = true
    }
  }
}

resource "aiven_service_integration" "grafana_dash_integration" {
  project                  = var.aiven_project_name
  integration_type         = "dashboard"
  depends_on = [ aiven_grafana.grafana, aiven_influxdb.influxdb ]
  source_service_name      = aiven_grafana.grafana.service_name
  destination_service_name = aiven_influxdb.influxdb.service_name
}