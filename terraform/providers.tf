# All providers read the same local kubeconfig context (Rancher Desktop).
# No remote backend/state store is configured on purpose — this is a laptop-local
# lab environment. If you later want a shared/remote state (e.g. once this moves to a
# real dev cluster), add a `backend` block here.

variable "kubeconfig_path" {
  description = "Path to kubeconfig. Rancher Desktop writes to ~/.kube/config by default."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "kubeconfig context to use."
  type        = string
  default     = "rancher-desktop"
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
  }
}

# No provider block needed for "local" or "null" — they don't talk to Kubernetes at
# all; "null"'s local-exec provisioners just shell out to whatever `kubectl` is on your
# PATH (Rancher Desktop's own binary), the same one you'd run by hand.
