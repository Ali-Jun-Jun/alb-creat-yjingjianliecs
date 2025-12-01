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
# 2. 阿里云 Provider 配置（需与已有资源同地域）
# ==============================
provider "alicloud" {
  region = "cn-beijing"  # 必须与已有 VPC/ECS 同地域
  # 认证方式：环境变量（推荐）或直接配置（不推荐硬编码）
  # access_key = "你的AK"
  # secret_key = "你的SK"
}

# ==============================
# 3. 自动查询已有资源（通过数据源，无需手动填 ID）
# ==============================
# 3.1 查询已有 VPC（按名称过滤，替换为你的 VPC 名称）
data "alicloud_vpcs" "existing" {
  name_regex = "test-vpc"  # 关键：替换为你实际的 VPC 名称（必须完全匹配或用正则）
}

# 3.2 查询已有子网（属于上述 VPC + 按标签过滤，确保是双子网）
data "alicloud_vswitches" "existing" {
  vpc_id = data.alicloud_vpcs.existing.ids[0]  # 关联查询到的 VPC
  tags = {
    Env = "test"  # 关键：替换为你子网的实际标签（无标签可删除 tags 块，按 VPC 过滤）
  }
  # 确保查询到至少 2 个子网（跨可用区），否则报错
  count = length(data.alicloud_vpcs.existing.ids) > 0 ? 1 : 0
}

# 3.3 查询已有 ECS 实例（属于上述 VPC + 按标签过滤，确保是两台）
data "alicloud_instances" "existing" {
  vpc_id = data.alicloud_vpcs.existing.ids[0]  # 关联查询到的 VPC
  tags = {
    Env = "test"  # 关键：替换为你 ECS 的实际标签（无标签可删除 tags 块）
  }
  # 确保查询到至少 2 台 ECS，否则报错
  count = length(data.alicloud_vpcs.existing.ids) > 0 ? 1 : 0
}

# 3.4 查询已有安全组（属于上述 VPC + 按名称过滤，替换为你的安全组名称）
data "alicloud_security_groups" "existing" {
  vpc_id     = data.alicloud_vpcs.existing.ids[0]  # 关联查询到的 VPC
  name_regex = "test-sg"  # 关键：替换为你实际的安全组名称
}

# ==============================
# 4. 公网 ALB 实例配置（核心资源）
# ==============================
resource "alicloud_alb_load_balancer" "public_alb" {
  # ALB 名称（自定义）
  load_balancer_name = "public-alb-test"
  # 类型：应用型 ALB
  load_balancer_type = "Application"
  # 关联自动查询到的 VPC
  vpc_id             = data.alicloud_vpcs.existing.ids[0]
  # 网络类型：公网（支持外部访问）
  address_type       = "Internet"
  # 公网计费模式：按流量计费（适合测试）
  internet_charge_type = "PayByTraffic"
  # 公网带宽峰值（按需调整，最小 1 Mbps）
  internet_bandwidth = 5

  # 绑定自动查询到的双子网（跨可用区，确保高可用）
  zone_mappings = [
    for idx, subnet in data.alicloud_vswitches.existing[0].switches : {
      zone_id    = subnet.zone_id  # 自动获取子网所在可用区
      vswitch_id = subnet.id       # 自动获取子网 ID
    }
  ]

  tags = {
    Name = "public-alb-test"
    Env  = "test"
  }
}

# ==============================
# 5. ALB 监听（80 端口 HTTP 协议）
# ==============================
resource "alicloud_alb_listener" "http_80" {
  load_balancer_id = alicloud_alb_load_balancer.public_alb.id
  listener_name    = "http-80-public"
  port             = 80
  protocol         = "HTTP"

  # 前端配置（HTTP 协议，无需证书）
  frontend_config = {
    protocol = "HTTP"
    port     = 80
  }

  # 默认转发到目标组
  default_actions = [
    {
      type             = "ForwardGroup"
      forward_group_id = alicloud_alb_forward_group.ecs_target.id
    }
  ]

  # 健康检查（检测 ECS 上的 Nginx 状态）
  health_check_config = {
    enabled             = true
    protocol            = "HTTP"
    port                = 80  # ECS 上 Nginx 监听端口
    path                = "/"  # 健康检查路径（Nginx 首页）
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 3
    interval            = 5
    healthy_http_codes  = "200-299"  # 健康状态码
  }

  # 会话保持（测试环境关闭）
  session_sticky_config = {
    enabled = false
  }
}

# ==============================
# 6. 目标组（管理已有 ECS 实例）
# ==============================
resource "alicloud_alb_forward_group" "ecs_target" {
  forward_group_name = "ecs-target-group-public"
  load_balancer_id   = alicloud_alb_load_balancer.public_alb.id
  target_type        = "Instance"  # 目标类型：ECS 实例
  scheduler          = "RoundRobin"  # 轮询算法
}

# ==============================
# 7. 绑定已有 ECS 到目标组
# ==============================
resource "alicloud_alb_forward_group_attachment" "ecs_attach" {
  # 循环绑定所有查询到的 ECS（数量与查询结果一致）
  count              = length(data.alicloud_instances.existing[0].instances)
  forward_group_id   = alicloud_alb_forward_group.ecs_target.id
  target_id          = data.alicloud_instances.existing[0].instances[count.index].id  # 自动获取 ECS ID
  port               = 80  # ECS 上 Nginx 端口
  weight             = 100  # 权重（所有 ECS 相同）
  zone_id            = data.alicloud_instances.existing[0].instances[count.index].zone_id  # 自动获取 ECS 可用区
}

# ==============================
# 8. 可选：给 ECS 安全组添加内网 80 端口放行规则（确保 ALB 能访问 ECS）
# ==============================
resource "alicloud_security_group_rule" "allow_alb_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"  # 内网访问（ALB 属于 VPC 内资源）
  policy            = "accept"
  port_range        = "80/80"     # Nginx 端口
  priority          = 5
  security_group_id = data.alicloud_security_groups.existing.ids[0]  # 自动关联已有安全组
  cidr_ip           = "0.0.0.0/0"  # 内网访问，安全风险低
}

# ==============================
# 9. 输出公网 ALB 访问信息
# ==============================
output "public_alb_info" {
  value = {
    alb_id           = alicloud_alb_load_balancer.public_alb.id
    alb_name         = alicloud_alb_load_balancer.public_alb.load_balancer_name
    public_ip        = alicloud_alb_load_balancer.public_alb.address  # 公网访问 IP
    access_url       = "http://${alicloud_alb_load_balancer.public_alb.address}:80"  # 公网访问地址
    listener_port    = alicloud_alb_listener.http_80.port
    bound_ecs_ids    = [for ecs in data.alicloud_instances.existing[0].instances : ecs.id]  # 已绑定的 ECS ID
    bandwidth        = alicloud_alb_load_balancer.public_alb.internet_bandwidth  # 公网带宽
  }
  description = "公网 ALB 配置信息及访问地址"
}
