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
# 3. 自动查询已有资源（仅查询 ECS 和安全组，无需 VPC/子网）
# ==============================
# 3.1 查询已有 ECS（按标签过滤，替换为你的 ECS 标签）
data "alicloud_instances" "existing" {
  tags = {
    Env = "test"  # 无标签可删除此块，或用 name_regex 按名称过滤
  }
}

# 3.2 查询已有安全组（按名称过滤，替换为你的安全组名称）
data "alicloud_security_groups" "existing" {
  name_regex = "test-sg"
}

# ==============================
# 4. 公网 CLB 实例（极低版本兼容：经典网络 CLB）
# ==============================
resource "alicloud_slb_load_balancer" "public_clb" {
  # 基本信息（极低版本仅支持这些核心参数）
  load_balancer_name = "public-clb-test"
  address_type       = "internet"  # 公网类型
  internet_charge_type = "paybytraffic"  # 按流量计费

  # 极低版本不支持 vpc_id、vswitch_ids、internet_bandwidth，这些参数全部移除
  # 带宽默认按流量计费，无需指定（阿里云自动分配基础带宽）

  tags = {
    Name = "public-clb-test"
    Env  = "test"
  }
}

# ==============================
# 5. CLB 监听（80 端口 HTTP 协议）
# ==============================
resource "alicloud_slb_listener" "http_80" {
  load_balancer_id = alicloud_slb_load_balancer.public_clb.id
  port             = 80
  protocol         = "http"
  backend_port     = 80  # 转发到 ECS 的 80 端口（Nginx）
  scheduler        = "round_robin"  # 轮询算法

  # 健康检查（极低版本支持的基础配置）
  health_check {
    enabled             = true
    type                = "http"
    uri                 = "/"  # 检查 Nginx 首页
    healthy_http_status = "http_2xx"
    interval            = 5
    timeout             = 3
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  sticky_session = "off"  # 关闭会话保持
}

# ==============================
# 6. 绑定 VPC ECS 到 CLB 后端（跨网络绑定）
# ==============================
resource "alicloud_slb_backend_server" "ecs_attach" {
  count             = length(data.alicloud_instances.existing.instances)
  load_balancer_id  = alicloud_slb_load_balancer.public_clb.id
  backend_server_id = data.alicloud_instances.existing.instances[count.index].id
  weight            = 100
  type              = "ecs"
  # 关键：指定 ECS 所在的 VPC ID（实现经典 CLB 绑定 VPC ECS）
  vpc_id            = data.alicloud_instances.existing.instances[count.index].vpc_id
}

# ==============================
# 7. 安全组规则（放行公网 80 端口 + 内网 80 端口）
# ==============================
# 规则1：放行公网 80 端口（用户访问 CLB）
resource "alicloud_security_group_rule" "allow_public_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "internet"
  policy            = "accept"
  port_range        = "80/80"
  priority          = 4
  security_group_id = data.alicloud_security_groups.existing.ids[0]
  cidr_ip           = "0.0.0.0/0"
}

# 规则2：放行内网 80 端口（CLB 转发到 ECS）
resource "alicloud_security_group_rule" "allow_intranet_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "80/80"
  priority          = 5
  security_group_id = data.alicloud_security_groups.existing.ids[0]
  cidr_ip           = "0.0.0.0/0"
}

# ==============================
# 8. 输出公网访问信息
# ==============================
output "public_clb_info" {
  value = {
    clb_id           = alicloud_slb_load_balancer.public_clb.id
    clb_name         = alicloud_slb_load_balancer.public_clb.load_balancer_name
    public_ip        = alicloud_slb_load_balancer.public_clb.address  # 公网 IP
    access_url       = "http://${alicloud_slb_load_balancer.public_clb.address}:80"  # 公网访问地址
    listener_port    = alicloud_slb_listener.http_80.port
    bound_ecs_ids    = [for ecs in data.alicloud_instances.existing.instances : ecs.id]
  }
  description = "公网 CLB 配置信息及访问地址"
}
