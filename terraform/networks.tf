
# vpc를 정의한다.
resource "aws_vpc" "test_vpc" {
  cidr_block = "172.17.0.0/20"

  tags {
    Name = "${var.test_vpc_tag_name} vpc"
  }
}

# 정의한 vpc를 위한 internet gateway를 붙인다.
resource "aws_internet_gateway" "test_vpc_igw" {
  vpc_id = "${aws_vpc.test_vpc.id}"

  tags {
    Name = "${var.test_vpc_tag_name} igw"
  }
}

# vpc의 라우트 테이블을 추가하고,
# internet gateway의 route table rule를 추가한다.
resource "aws_route_table" "test_vpc_router" {
  vpc_id = "${aws_vpc.test_vpc.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.test_vpc_igw.id}"
  }

  tags {
    Name = "${var.test_vpc_tag_name} router"
  }
}

# vpc에서 사용 할 서브넷을 정의한다.
resource "aws_subnet" "test_vpc_subnet" {
  vpc_id = "${aws_vpc.test_vpc.id}"
  cidr_block = "${cidrsubnet(aws_vpc.test_vpc.cidr_block, 4, 1)}"
  availability_zone = "ap-northeast-2a"

  tags {
    Name = "${var.test_vpc_tag_name} subnet"
  }
}

# 서브넷과 라우트 테이블을 연결한다.
resource "aws_route_table_association" "test_vpc_routing_association" {
  subnet_id      = "${aws_subnet.test_vpc_subnet.id}"
  route_table_id = "${aws_route_table.test_vpc_router.id}"
}

# vpc의 시큐리티 그룹을 추가한다.
resource "aws_security_group" "test_vpc_allow_all" {
  name = "test_vpc_allow_all"
  description = "allows all in/out bounds (managed in terraform)"
  vpc_id = "${aws_vpc.test_vpc.id}"

  ingress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "${var.test_vpc_tag_name} sg"
  }
}
