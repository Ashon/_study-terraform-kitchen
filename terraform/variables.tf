
variable "test_vpc_tag_name" {
  type = "string"
  default = "test_network"
}

variable "test_keypair_public_key" {
  type = "string"

  # ec2 instance에 접속할 때 사용할 EC2 Keypair의 public_key 정보
  default = "ssh-rsa .. testuser@hello.com"
}
