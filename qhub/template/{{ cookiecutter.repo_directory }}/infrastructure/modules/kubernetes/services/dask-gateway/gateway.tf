resource "kubernetes_secret" "gateway" {
  metadata {
    name      = "${var.name}-daskgateway-gateway"
    namespace = var.namespace
  }

  data = {
    "jupyterhub_api_token" = var.jupyterhub_api_token
  }
}


resource "kubernetes_config_map" "gateway" {
  metadata {
    name      = "${var.name}-daskgateway-gateway"
    namespace = var.namespace
  }

  data = {
    "dask_gateway_config.py" = templatefile(
      "${path.module}/templates/gateway_config.py", {
        gateway_service_name      = kubernetes_service.gateway.metadata.0.name
        gateway_service_namespace = kubernetes_service.gateway.metadata.0.namespace
        jupyterhub_api_url        = var.jupyterhub_api_url
        gateway                   = var.gateway
        cluster                   = var.cluster
        cluster-image             = var.cluster-image
        extra_config              = var.extra_config
    })
  }
}


resource "kubernetes_service_account" "gateway" {
  metadata {
    name      = "${var.name}-daskgateway-gateway"
    namespace = var.namespace
  }
}


resource "kubernetes_cluster_role" "gateway" {
  metadata {
    name = "${var.name}-daskgateway-gateway"
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get"]
  }

  rule {
    api_groups = ["gateway.dask.org"]
    resources  = ["daskclusters"]
    verbs      = ["*"]
  }
}


resource "kubernetes_cluster_role_binding" "gateway" {
  metadata {
    name = "${var.name}-daskgateway-gateway"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.gateway.metadata.0.name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.gateway.metadata.0.name
    namespace = var.namespace
  }
}


resource "kubernetes_service" "gateway" {
  metadata {
    name      = "${var.name}-dask-gateway-gateway-api"
    namespace = var.namespace
  }

  spec {
    selector = {
      "app.kubernetes.io/component" = "dask-gateway-gateway"
    }

    port {
      name        = "api"
      protocol    = "TCP"
      port        = 8000
      target_port = 8000
    }

    type = "ClusterIP"
  }
}


resource "kubernetes_deployment" "gateway" {
  metadata {
    name      = "${var.name}-daskgateway-gateway"
    namespace = var.namespace
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/component" = "dask-gateway-gateway"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/component" = "dask-gateway-gateway"
        }

        annotations = {
          # This lets us autorestart when the secret changes!
          "checksum/config-map" = sha256(jsonencode(kubernetes_config_map.gateway.data))
          "checksum/secret"     = sha256(jsonencode(kubernetes_secret.gateway.data))
        }
      }

      spec {
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = var.general-node-group.key
                  operator = "In"
                  values   = [var.general-node-group.value]
                }
              }
            }
          }
        }

        volume {
          name = "configmap"
          config_map {
            name = kubernetes_config_map.gateway.metadata.0.name
          }
        }

        service_account_name            = kubernetes_service_account.gateway.metadata.0.name
        automount_service_account_token = true

        container {
          image = "${var.gateway-image.name}:${var.gateway-image.tag}"
          name  = var.name

          command = [
            "dask-gateway-server",
            "--config",
            "/etc/dask-gateway/dask_gateway_config.py"
          ]

          volume_mount {
            name       = "configmap"
            mount_path = "/etc/dask-gateway/"
          }

          env {
            name = "JUPYTERHUB_API_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.gateway.metadata.0.name
                key  = "jupyterhub_api_token"
              }
            }
          }

          port {
            name           = "api"
            container_port = 8000
          }

          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "50Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/api/health"
              port = "api"
            }

            initial_delay_seconds = 5
            timeout_seconds       = 2
            period_seconds        = 10
            failure_threshold     = 6
          }

          readiness_probe {
            http_get {
              path = "/api/health"
              port = "api"
            }

            initial_delay_seconds = 5
            timeout_seconds       = 2
            period_seconds        = 10
            failure_threshold     = 3
          }
        }
      }
    }
  }
}
