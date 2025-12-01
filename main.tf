# ==============================
# 1. Terraform 版本与 Provider 约束
# ==============================
terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = ">= 1.200.0"
    }
  }
}

# ==============================
# 2. 阿里云 Provider 配置
# ==============================
provider "alicloud" {
  region = "cn-beijing"  # 与已有资源同地域
  # access_key = "你的AK"（按需配置）
  # secret_key = "你的SK"（按需配置）
}

# ==============================
# 3. 手动指定已有资源 ID（早期版本数据源可能不稳定，直接填 ID 最可靠）
# ==============================
variable "existing_resources" {
  type = object({
    ecs_ids        = list(string)  # 你的两台 ECS ID
    security_group_id = string  # 你的 ECS 安全组 ID
  })
  default = {
    # ########## 必须替换为你账号中的实际 ID ##########
    ecs_ids        = ["i-xxxxxxxxxxxxxxxxx", "i-xxxxxxxxxxxxxxxxx"]  # 替换为你的 ECS ID
    security_group_id = "sg-xxxxxxxxxxxxxxxxx"  # 替换为你的安全组 ID
    # ################################################
  }
}

# ==============================
# 4. 公网 CLB 实例（早期版本仅支持 3 个必填参数）
# ==============================
resource "alicloud_slb_load_balancer" "public_clb" {
  load_balancer_name = "public-clb-test"
  address_type       = "internet"  # 公网类型
  internet_charge_type = "paybytraffic"  # 按流量计费（必填）
}

# ==============================
# 5. CLB 监听（早期版本语法：frontend_port 替代 port，无健康检查块）
# ==============================
resource "alicloud_slb_listener" "http_80" {
  load_balancer_id = alicloud_slb_load_balancer.public_clb.id
  frontend_port    = 80  # 早期版本用 frontend_port 替代 port
  protocol         = "http"
  backend_port     = 80  # 转发到 ECS 80 端口
  scheduler        = "round_robin"  # 轮询算法
  health_check     = "on"  # 开启健康检查（仅支持开关，不支持复杂配置）
  healthy_http_code = "200"  # 健康状态码（简单配置）
}

# ==============================
# 6. 绑定 ECS 到 CLB（早期版本用 server_ids 参数，批量绑定）
# ==============================
resource "alicloud_slb_backend_servers" "ecs_attach" {  # 注意：资源名是复数 servers
  load_balancer_id = alicloud_slb_load_balancer.public_clb.id
  server_ids       = var.existing_resources.ecs_ids  # 批量传入 ECS ID 列表
  weights          = [100, 100]  # 两台 ECS 权重均为 100（与 ECS ID 顺序对应）
}

# ==============================
# 7. 安全组规则（放行公网+内网 80 端口）
# ==============================
# 规则1：公网 80 端口（用户访问 CLB）
resource "alicloud_security_group_rule" "allow_public_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "internet"
  policy            = "accept"
  port_range        = "80/80"
  priority          = 4
  security_group_id = var.existing_resources.security_group_id
  cidr_ip           = "0.0.0.0/0"
}

# 规则2：内网 80 端口（CLB 访问 ECS）
resource "alicloud_security_group_rule" "allow_intranet_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "80/80"
  priority          = 5
  security_group_id = var.existing_resources.security_group_id
  cidr_ip           = "0.0.0.0/0"
}

# ==============================
# 8. 输出公网访问信息
# ==============================
output "public_clb_info" {
  value = {
    clb_id           = alicloud_slb_load_balancer.public_clb.id
    clb_name         = alicloud_slb_load_balancer.public_clb.load_balancer_name
    public_ip        = alicloud_slb_load_balancer.public_clb.address  # 公网访问 IP
    access_url       = "http://${alicloud_slb_load_balancer.public_clb.address}:80"  # 公网访问地址
    bound_ecs_ids    = var.existing_resources.ecs_ids
  }
  description = "公网 CLB 配置信息及访问地址"
}
