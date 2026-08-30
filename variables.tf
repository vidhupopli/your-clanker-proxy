variable "region" {
  description = "AWS region for the proxy VPC and instance."
  type        = string
  default     = "ap-south-1"
}

variable "instance_type" {
  description = "ARM instance type. Must match the AL2023 arm64 AMI (t4g.nano is the cheap default)."
  type        = string
  default     = "t4g.nano"
}

variable "availability_zone" {
  description = "Optional AZ for the public subnet. Empty: pick from instance-type offerings (skip the first lexical AZ when others exist — ap-south-1a is often capacity-constrained). Set to ap-south-1b or ap-south-1c if apply fails with InsufficientInstanceCapacity."
  type        = string
  default     = ""
}

variable "allowed_cidrs" {
  description = "Optional extra SG restrictor for TCP 443. Empty (default) means 0.0.0.0/0 so roaming clients can connect. Password + destination whitelist still apply."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.allowed_cidrs : can(cidrnetmask(cidr))
    ])
    error_message = "Each allowed_cidrs entry must be a valid IPv4 CIDR (for example 203.0.113.10/32)."
  }
}

variable "proxy_user" {
  description = "HTTP CONNECT username. Password is generated and stored in SSM."
  type        = string
  default     = "starman"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.proxy_user))
    error_message = "proxy_user must be alphanumeric plus . _ - so it is safe in URLs and 3proxy config."
  }
}

variable "proxy_port" {
  description = "Host and 3proxy listen port. 443 is the default so corporate firewalls that block 3128 still work."
  type        = number
  default     = 443

  validation {
    condition     = var.proxy_port >= 1 && var.proxy_port <= 65535
    error_message = "proxy_port must be a valid TCP port."
  }
}

variable "name" {
  description = "Name/prefix for AWS resource names and tags."
  type        = string
  default     = "dev-proxy"

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]+$", var.name)) && length(var.name) <= 32
    error_message = "name must be 1–32 characters of letters, digits, or hyphens."
  }
}

variable "vpc_cidr" {
  description = "CIDR for the dedicated proxy VPC (not the account default VPC)."
  type        = string
  default     = "10.42.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for the single public subnet."
  type        = string
  default     = "10.42.0.0/24"
}

variable "proxy_allow_dests" {
  description = "CONNECT destination host patterns (3proxy wildcards). Destination port is always 443. Ignored when proxy_allow_all_dests is true."
  type        = list(string)
  default = [
    "*.cursor.sh",
    "*.cursor-cdn.com",
    "*.cursorapi.com",
    "*.cursorvm.com",
    "cursor.sh",
    "downloads.cursor.com",
    "anysphere-binaries.s3.us-east-1.amazonaws.com",
    "*.grok.com",
    "grok.com",
    "*.x.ai",
    "x.ai",
    "*.opencode.ai",
    "opencode.ai",
    "models.dev",
    "*.models.dev",
    "*.openrouter.ai",
    "openrouter.ai",
  ]
}

variable "proxy_allow_all_dests" {
  description = "Escape hatch: skip the destination host whitelist. CONNECT remains authenticated and destination port 443 only."
  type        = bool
  default     = false
}

variable "xai_api_key" {
  description = "Optional xAI key held on the server. Non-empty enables the HTTP gateway mux (with OpenRouter if set). Never commit this; use gitignored tfvars."
  type        = string
  default     = ""
  sensitive   = true
}

variable "openrouter_api_key" {
  description = "Optional OpenRouter key held on the server. Non-empty enables the HTTP gateway mux (with xAI if set). Never commit this; use gitignored tfvars."
  type        = string
  default     = ""
  sensitive   = true
}

variable "ssh_enabled" {
  description = "Open TCP 22 (same CIDRs as 443) and persist password SSH for var.proxy_user via SSM. Password is the CONNECT SSM parameter. No EC2 key pair."
  type        = bool
  default     = true
}

variable "domain_name" {
  description = "Public DNS name for Let's Encrypt (Route53 DNS-01) on the mux. Empty (default) keeps today's self-signed TLS on the EIP. Trim any trailing dot."
  type        = string
  default     = ""
}

variable "acme_email" {
  description = "Let's Encrypt account email. Required when domain_name is set. Empty when domain_name is empty."
  type        = string
  default     = ""

  validation {
    condition     = var.domain_name == "" || can(regex("^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$", var.acme_email))
    error_message = "acme_email must look like an email when domain_name is set."
  }
}
