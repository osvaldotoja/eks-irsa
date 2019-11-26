cluster_name   = "demo-eks-oidc"
hosted_zone_id = ""

vpc_cidr              = "10.99.192.0/18"
private_subnets_cidrs = ["10.99.192.0/20", "10.99.208.0/20", "10.99.224.0/20"]
public_subnets_cidrs  = ["10.99.240.0/22", "10.99.244.0/22", "10.99.248.0/22"]

vpc_single_nat_gateway     = true
vpc_one_nat_gateway_per_az = false

environment               = "test"
ssh_key_name              = "devops-default"
spot_worker_instance_type = "m5.4xlarge"
# spot_worker_instance_type = "m5.4xlarge"

# TODO: update to 1.14
eks_version = "1.13"
# https://docs.aws.amazon.com/eks/latest/userguide/eks-optimized-ami.html
# 1.14.7 / US West (Oregon) (us-west-2) / Amazon EKS-optimized AMI / ami-07be7092831897fd6
# 1.13.11 / US West (Oregon) (us-west-2) / Amazon EKS-optimized AMI / ami-04e247c4613de71fa
ami_id = "ami-04e247c4613de71fa"

tags = {
  Terraform    = "true"
  ServiceName  = "demo-eks-oidc"
  ServiceOwner = "demo@example.com"
  Environment  = "test"
  ServiceType = "demo-eks-oidc"
}

ondemand_number_of_nodes       = 1
ondemand_percentage_above_base = 0
spot_instance_pools            = 4

desired_number_worker_nodes = 4
min_number_worker_nodes     = 1
max_number_worker_nodes     = 5
