terraform {
  backend "local" {
    path = "/home/jenkins/tfstate/terraform.tfstate"
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
    confluent = {
      source  = "confluentinc/confluent"
      version = "1.38.0"
    }
  }
}

provider "confluent" {}

data "confluent_environment" "test" {
  id = "env-vo320"
}

data "confluent_schema_registry_region" "advanced" {
  cloud   = "AWS"
  region  = var.confluent_schema_registry_region
  package = "ADVANCED"
}

resource "confluent_schema_registry_cluster" "advanced" {
  package = data.confluent_schema_registry_region.advanced.package
  environment {
    id = data.confluent_environment.test.id
  }
  region {
    id = data.confluent_schema_registry_region.advanced.id
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "confluent_network" "private-link" {
  display_name     = "Private Link Network"
  cloud            = "AWS"
  region           = var.region
  connection_types = ["PRIVATELINK"]
  zones            = keys(var.subnets_to_privatelink)
  environment {
    id = data.confluent_environment.test.id
  }
}

resource "confluent_private_link_access" "aws" {
  display_name = "AWS Private Link Access"
  aws {
    account = var.aws_account_id
  }
  environment {
    id = data.confluent_environment.test.id
  }
  network {
    id = confluent_network.private-link.id
  }
}

resource "confluent_kafka_cluster" "dedicated" {
  display_name = "Novigrad"
  availability = "MULTI_ZONE"
  cloud        = confluent_network.private-link.cloud
  region       = confluent_network.private-link.region
  dedicated {
    cku = 2
  }
  environment {
    id = data.confluent_environment.test.id
  }
  network {
    id = confluent_network.private-link.id
  }
}

resource "confluent_service_account" "cool-manager" {
  display_name = "cool-manager"
  description  = "Service account to manage 'awesome' Kafka cluster"
}

resource "confluent_role_binding" "cool-manager-kafka-cluster-admin" {
  principal   = "User:${confluent_service_account.cool-manager.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.dedicated.rbac_crn
}

resource "confluent_api_key" "cool-manager-kafka-api-key" {
  display_name = "cool-manager-kafka-api-key"
  description  = "Kafka API Key that is owned by 'cool-manager' service account"
  
  # disable_wait_for_ready = true

  owner {
    id          = confluent_service_account.cool-manager.id
    api_version = confluent_service_account.cool-manager.api_version
    kind        = confluent_service_account.cool-manager.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.dedicated.id
    api_version = confluent_kafka_cluster.dedicated.api_version
    kind        = confluent_kafka_cluster.dedicated.kind

    environment {
      id = data.confluent_environment.test.id
    }
  }

  depends_on = [
    confluent_role_binding.cool-manager-kafka-cluster-admin,

    confluent_private_link_access.aws,
    aws_vpc_endpoint.privatelink,
    aws_route53_record.privatelink,
    aws_route53_record.privatelink-zonal,
  ]
}

resource "confluent_kafka_topic" "orders" {
  kafka_cluster {
    id = confluent_kafka_cluster.dedicated.id
  }
  topic_name    = "orders"
  rest_endpoint = confluent_kafka_cluster.dedicated.rest_endpoint
  credentials {
    key    = confluent_api_key.cool-manager-kafka-api-key.id
    secret = confluent_api_key.cool-manager-kafka-api-key.secret
  }
}

resource "confluent_service_account" "cool-consumer" {
  display_name = "cool-consumer"
  description  = "Service account to consume from 'orders' topic of 'awesome' Kafka cluster"
}

resource "confluent_api_key" "cool-consumer-kafka-api-key" {
  display_name = "cool-consumer-kafka-api-key"
  description  = "Kafka API Key that is owned by 'cool-consumer' service account"

  # disable_wait_for_ready = true

  owner {
    id          = confluent_service_account.cool-consumer.id
    api_version = confluent_service_account.cool-consumer.api_version
    kind        = confluent_service_account.cool-consumer.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.dedicated.id
    api_version = confluent_kafka_cluster.dedicated.api_version
    kind        = confluent_kafka_cluster.dedicated.kind

    environment {
      id = data.confluent_environment.test.id
    }
  }
  
  depends_on = [
    confluent_private_link_access.aws,
    aws_vpc_endpoint.privatelink,
    aws_route53_record.privatelink,
    aws_route53_record.privatelink-zonal,
  ]
}

resource "confluent_service_account" "cool-producer" {
  display_name = "cool-producer"
  description  = "Service account to produce to 'orders' topic of 'awesome' Kafka cluster"
}

resource "confluent_api_key" "cool-producer-kafka-api-key" {
  display_name = "cool-producer-kafka-api-key"
  description  = "Kafka API Key that is owned by 'cool-producer' service account"

  # disable_wait_for_ready = true

  owner {
    id          = confluent_service_account.cool-producer.id
    api_version = confluent_service_account.cool-producer.api_version
    kind        = confluent_service_account.cool-producer.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.dedicated.id
    api_version = confluent_kafka_cluster.dedicated.api_version
    kind        = confluent_kafka_cluster.dedicated.kind

    environment {
      id = data.confluent_environment.test.id
    }
  }

  depends_on = [
    confluent_private_link_access.aws,
    aws_vpc_endpoint.privatelink,
    aws_route53_record.privatelink,
    aws_route53_record.privatelink-zonal,
  ]
}

resource "confluent_kafka_acl" "cool-consumer-read-on-topic" {
  kafka_cluster {
    id = confluent_kafka_cluster.dedicated.id
  }
  resource_type = "TOPIC"
  resource_name = confluent_kafka_topic.orders.topic_name
  pattern_type  = "LITERAL"
  principal     = "User:${confluent_service_account.cool-consumer.id}"
  host          = "*"
  operation     = "READ"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.dedicated.rest_endpoint
  credentials {
    key    = confluent_api_key.cool-manager-kafka-api-key.id
    secret = confluent_api_key.cool-manager-kafka-api-key.secret
  }
}

resource "confluent_kafka_acl" "cool-consumer-read-on-group" {
  kafka_cluster {
    id = confluent_kafka_cluster.dedicated.id
  }
  resource_type = "GROUP"
  resource_name = "cool_group_"
  pattern_type  = "PREFIXED"
  principal     = "User:${confluent_service_account.cool-consumer.id}"
  host          = "*"
  operation     = "READ"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.dedicated.rest_endpoint
  credentials {
    key    = confluent_api_key.cool-manager-kafka-api-key.id
    secret = confluent_api_key.cool-manager-kafka-api-key.secret
  }
}

resource "confluent_kafka_acl" "cool-producer-write-on-topic" {
  kafka_cluster {
    id = confluent_kafka_cluster.dedicated.id
  }
  resource_type = "TOPIC"
  resource_name = confluent_kafka_topic.orders.topic_name
  pattern_type  = "LITERAL"
  principal     = "User:${confluent_service_account.cool-producer.id}"
  host          = "*"
  operation     = "WRITE"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.dedicated.rest_endpoint
  credentials {
    key    = confluent_api_key.cool-manager-kafka-api-key.id
    secret = confluent_api_key.cool-manager-kafka-api-key.secret
  }
}

provider "aws" {}

data "aws_vpc" "privatelink" {
  id = var.vpc_id
}

data "aws_availability_zone" "privatelink" {
  for_each = var.subnets_to_privatelink
  zone_id  = each.key
}

locals {
  hosted_zone = length(regexall(".glb", confluent_kafka_cluster.dedicated.bootstrap_endpoint)) > 0 ? replace(regex("^[^.]+-([0-9a-zA-Z]+[.].*):[0-9]+$", confluent_kafka_cluster.dedicated.bootstrap_endpoint)[0], "glb.", "") : regex("[.]([0-9a-zA-Z]+[.].*):[0-9]+$", confluent_kafka_cluster.dedicated.bootstrap_endpoint)[0]
}

locals {
  bootstrap_prefix = split(".", confluent_kafka_cluster.dedicated.bootstrap_endpoint)[0]
}

resource "aws_security_group" "privatelink" {
  # Ensure that SG is unique, so that this module can be used multiple times within a single VPC
  name        = "ccloud-privatelink_${local.bootstrap_prefix}_${var.vpc_id}"
  description = "Confluent Cloud Private Link minimal security group for ${confluent_kafka_cluster.dedicated.bootstrap_endpoint} in ${var.vpc_id}"
  vpc_id      = data.aws_vpc.privatelink.id

  ingress {
    # only necessary if redirect support from http/https is desired
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.privatelink.cidr_block]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.privatelink.cidr_block]
  }

  ingress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.privatelink.cidr_block]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_endpoint" "privatelink" {
  vpc_id            = data.aws_vpc.privatelink.id
  service_name      = confluent_network.private-link.aws[0].private_link_endpoint_service
  vpc_endpoint_type = "Interface"

  security_group_ids = [
    aws_security_group.privatelink.id,
  ]

  subnet_ids          = [for zone, subnet_id in var.subnets_to_privatelink : subnet_id]
  private_dns_enabled = false

  depends_on = [
    confluent_private_link_access.aws,
  ]
}

resource "aws_route53_zone" "privatelink" {
  name = local.hosted_zone

  vpc {
    vpc_id = data.aws_vpc.privatelink.id
  }
}

resource "aws_route53_record" "privatelink" {
  count   = length(var.subnets_to_privatelink) == 1 ? 0 : 1
  zone_id = aws_route53_zone.privatelink.zone_id
  name    = "*.${aws_route53_zone.privatelink.name}"
  type    = "CNAME"
  ttl     = "60"
  records = [
    aws_vpc_endpoint.privatelink.dns_entry[0]["dns_name"]
  ]
}

locals {
  endpoint_prefix = split(".", aws_vpc_endpoint.privatelink.dns_entry[0]["dns_name"])[0]
}

resource "aws_route53_record" "privatelink-zonal" {
  for_each = var.subnets_to_privatelink

  zone_id = aws_route53_zone.privatelink.zone_id
  name    = length(var.subnets_to_privatelink) == 1 ? "*" : "*.${each.key}"
  type    = "CNAME"
  ttl     = "60"
  records = [
    format("%s-%s%s",
      local.endpoint_prefix,
      data.aws_availability_zone.privatelink[each.key].name,
      replace(aws_vpc_endpoint.privatelink.dns_entry[0]["dns_name"], local.endpoint_prefix, "")
    )
  ]
}
