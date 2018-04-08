# study terraform-kitchen

테라폼 리소스를 `terraform-kitchen`으로 테스트해 보는 예제.

## 시작하기 앞서 알아두면 좋을 것들.

### Terraform

IT 서비스를 위해서는 애플리케이션 개발도 중요하지만, 그 밑바탕이 되는 인프라 자원들의 관리도 중요하다.

퍼블릭 클라우드를 이용해서 인프라를 관리할 때, 형상을 코드로 정의해서 관리할 수 있게 해 주는 도구이다.

### Kitchen CI (test-kitchen)

`chef`에서 떨어져 나온 인프라 테스트 프레임워크이다.

여러 프로바이더들을 지원하고, 여러 테스트러너들을 이용해서 테스트 워크플로우를 만들어 준다.

### Inspec

`terraform-kitchen`에서 사용하고 있는 테스트러너

## 테스트 인프라 구성: 사용할 AWS 인프라 환경을 테라폼 리소스로 정의

테스트를 하려면 테스트 할 대상이 필요하다. 서비스로 사용할 자원들을 `terraform`으로 정의해 본다.

예제 치곤 좀 복잡할 수 있는데, 인스턴스 전용 VPC를 구성해 보고 그 안에서 생성된 인스턴스까지
트래픽이 잘 전달되는지 알아본다.

### providers

여기서 관리할 테라폼 리소스들은 `AWS`를 사용할 것이므로, aws provider를 선언한다.

``` hcl
# file: ./terraform/providers.tf
# provider 설정 정보는 environment variable로 관리할 것이기 때문에,
# aws provider를 사용한다고만 선언하고 별도의 설정값은 쓰지 않는다.

provider "aws" { /* managed with environment variables. */ }
```

### data

ec2 인스턴스를 정의할 때 ami id가 필요한데, aws api를 통해서 ami id를 가져올 수 있도록 한다.
굳이 data로 정의 할 필요는 없지만, 해 놓으면 `ami = "${data.aws_ami.ubuntu_xenial.id}"`로
편리하게 참조해서 사용할 수 있다.

``` hcl
# file: ./terraform/data.tf

data "aws_ami" "ubuntu_xenial" {
  most_recent = true

  filter {
    name = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-xenial-16.04-amd64-server-*"]
  }

  filter {
    name = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}
```

### networks

이제 인스턴스를 정의해서 바로 써도 되는데, 그러면 `default VPC`를 사용해야 한다.
디테일을 좀 더 살리기 위해 서비스를 위한 별도의 vpc와 관련 네트워크 리소스 설정을 해 보자.

``` hcl
# file: ./terraform/networks.tf
# vpc, internet gateway, route table, subnet, security group을 정의한다.
#
#                   <------ route table ------->
# public --traffic--> igw --> vpc --> subnet --> ec2 instance

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
```

### keypair

인스턴스가 들어갈 네트워크도 정의가 다 되었고, 인스턴스를 선언해야 하는데, 타겟 인스턴스에 접근을 위해서는
`keypair`가 필요하다. `keypair`도 정의해 준다.

``` hcl
# file: ./terraform/keypair.tf

resource "aws_key_pair" "test_keypair" {
  key_name   = "test_keypair"
  public_key = "${var.test_keypair_public_key}"
}
```

### instances

이제 인스턴스를 정의해 본다. 일단 예제니까 ssh 접근을 위해 elastic ip도 붙여보자..
실제 사용할 때는 security group이나 네트워크 보안쪽을 더 확실하게 해 둘 필요가 있을 것 같다.

``` hcl
# file: ./terraform/instances.tf

resource "aws_instance" "test_compute" {
  ami = "${data.aws_ami.ubuntu_xenial.id}"

  instance_type = "t2.micro"
  count = 1

  subnet_id = "${aws_subnet.test_vpc_subnet.id}"
  vpc_security_group_ids = [
    "${aws_security_group.test_vpc_allow_all.id}"
  ]
  associate_public_ip_address = true

  key_name = "${aws_key_pair.test_keypair.key_name}"

  tags {
    Name = "${var.test_vpc_tag_name} compute-ubuntu-xenial"
  }
}
```

### variables

리소스들의 변수로 `test_vpc_tag_name`과 `test_keypair_public_key`가 사용되고 있으니,
해당 변수들도 선언한다.

``` hcl
# file: ./terraform/variables.tf

variable "test_vpc_tag_name" {
  type = "string"
  default = "test_network"
}

variable "test_keypair_public_key" {
  type = "string"

  # ec2 instance에 접속할 때 사용할 EC2 Keypair의 public_key 정보
  # repo에 포함되면 위험하니까 더미값을 설정해 두자.
  default = "ssh-rsa .. testuser@hello.com"
}
```

### init, plan, apply

모든 리소스가 선언 되었으니 terraform을 위한 부트스트랩 작업을 한다.

``` sh
$ cd ./terraform
$ terraform init
:

# autoenv 같은 도구를 이용하면 편리하게 관리할 수 있다.
$ export AWS_ACCESS_KEY_ID="an_access_key"
$ export AWS_SECRET_ACCESS_KEY="a_secret_key"
$ export AWS_DEFAULT_REGION="ap-northeast-2"
```

`plan`을 해서 적용 이전에 `dry-run`을 해 본다.
`test_keypair_public_key` 변수로 관리하고 있기 때문에, 꼭 실제 사용할 `keypair`로 할당해 줘야한다.

``` sh
# TF_VAR_{{ variable name }}으로 환경변수로 넘길 수 있다.
$ TF_VAR_test_keypair_public_key=$(cat ~/.ssh/id_rsa.pub) terraform plan

:

Plan: 8 to add, 0 to change, 0 to destroy.

:
```

`apply`를 해서 런타임에 반영을 한다. `aws_key_pair` 리소스에 사용되는 public key 내용을
반드시 명시한다.

``` sh
$ TF_VAR_test_keypair_public_key=$(cat ~/.ssh/id_rsa.pub) terraform apply

:

Apply complete! Resources: 8 added, 0 changed, 0 destroyed.
```

`Apply`가 잘 된것을 확인했다. 돈 아까우니 잽싸게 내리자..

``` sh
$ TF_VAR_test_keypair_public_key=$(cat ~/.ssh/id_rsa.pub) terraform destroy

:
```

## terraform-kitchen

코드로 정의하고 자동화 되는 것만으로는 충분하지 않다.

해당 코드가 올바르게 동작하는지 확인을 위해서는 테스트 케이스를 작성하고 관리해야 한다.
`terraform-kitchen`은 `chef`의 프로비저닝 테스트 도구인 `test-kitchen`의 플러그인인데,
`terraform`으로 관리되는 인프라 자원들에 대한 `verification`을 수행해 주는 도구이다.

### test-kitchen

`test-kitchen`는 테스트 셋의 상태를 단계별로 하고 있다.
각 단계별로 명령어들이 존재하며 상태를 단계별로 알아보면..

- create: 정의된 리소스가 셋업되는 단계
- converge: 셋업 된 인스턴스 위에 프로비저닝 코드를 전개하는 단계
- verify: 프로비저닝 된 인스턴스를 대상으로 테스트 도구를 설치하고 테스트를 수행하는 단계
- destroy: 인스턴스를 destroy

대략 이정도인데, `terraform-kitchen`은

- create: `terraform init`을 수행. 각 플러그인들과 모듈들을 로드하는 단계
- converge: `terraform apply`를 수행하고 리소스들의 아웃풋을 모은다.
- verify: 리소스들의 output으로 verification을 수행하거나, 인스턴스에 직접 접근해서 테스트를 수행한다.
- destroy: `terraform destroy`로 전개된 테스트 셋을 제거한다.

로 상태가 관리된다. 그리고 `terraform-kitchen`에서는 테스트 셋을 관리하기 위한 자신만의
`workspace`를 가지는데 이 부분도 참고하자.

### terraform-kitchen 준비

[공식 문서](https://github.com/newcontext-oss/kitchen-terraform)에도
`terraform-kitchen`을 사용하는 방법을 기술해 놓긴 했지만,
여기선 이전에 정의한 리소스를 대상으로 테스트 해 보기로 하였다.

`Bundler`로 `terraform-kitchen`을 준비하자.
나는 `rbenv`를 이용해서 머신의 ruby 버전을 관리하는데, 이 예제에서는 `2.4.0`을 사용하였다. (`./.ruby-version`)

``` ruby
# file: ./Gemfile
source 'https://rubygems.org/' do
  gem 'kitchen-terraform', '3.1.0'
end
```

``` sh
# Gemfile에 정의한 패키지를 설치한다.
$ bundle
:
```

### kitchen 설정 준비하기

kitchen 테스트를 수행하기 위해서는 `.kitchen.yml`에 test runtime에 대한 설정정보가 필요하다.

``` yaml
# file: ./.kitchen.yml

---
driver:
  name: terraform

  # terraform resource는 ./terraform 디렉토리에서 관리되고 있으므로
  # 해당 디렉토리를 설정해 준다. 기본값은 현재 위치
  root_module_directory: ./terraform

  # test-kitchen에서는 설정파일을 템플릿 엔진을 이용해서 읽어들이므로
  # 아래처럼 terraform variable을 환경변수의 값으로 할당하는 등의 조작이 가능하다.
  variables:
    test_keypair_public_key: "<%= ENV['TF_VAR_test_keypair_public_key'] %>"

  # 만약 tfstate를 리모트로 관리하고 있다면,
  # 해당 설정에서 tfstate의 경로를 지정해 주면 된다.
  # ref: http://www.rubydoc.info/github/newcontext-oss/kitchen-terraform/Kitchen/Driver/Terraform
  # backend_configurations:
  #   address: demo.consul.io
  #   path: example_app/terraform_state

provisioner:
  name: terraform

platforms:
  - name: example-infra

transport:
  name: ssh
  username: ubuntu
  ssh_key: ~/.ssh/id_rsa

verifier:
  name: terraform
  reporter: doc
  groups:
    - name: default
      controls:
        - operating_system
      hostnames: public_ip
      username: ubuntu

suites:
  - name: default
```

### Inspec test code 작성하기

inspec은 잘 모르지만 rspec처럼 생겨서, 생각보다 작성하기 쉬웠다.

``` sh
$ tree
test
└── integration
    └── default
        ├── controls
        │   └── operating_system_spec.rb # 테스트 코드
        └── inspec.yml # inspec 설정
```

``` yml
# file: ./test/integration/default/inspec.yml
---
name: default
```

``` ruby
# file: ./test/integration/default/controls/operatic_system_spec.rb
control 'operating_system' do
  describe command('lsb_release -a') do
    its('stdout') { should match (/Ubuntu/) }
  end
end
```

### kitchen status로 테스트 상태 확인하기

```sh
$ kitchen status

:

Instance               Driver     Provisioner  Verifier   Transport  Last Action    Last Error
default-example-infra  Terraform  Terraform    Terraform  Ssh        <Not Created>  <None>
```

### kitchen create로 테스트를 수행하기 위한 부트스트래핑

``` sh
$ kitchen create

# terraform init과 kitchen test 전용 workspace를 만든다.
```

### kitchen converge로 테라폼 인스턴스 전개

전개하기 전 필요한 환경변수들이 잘 정의되었는지 확인해 보자
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_DEFAULT_REGION`,
- `TF_VAR_test_keypair_public_key`

``` sh
$ kitchen converge

# terraform apply를 하고 이후 나온 output들을 변수로 매핑한다.
```

### kitchen verify로 Inspec테스트 돌리기

``` sh
$ kitchen verify
-----> Starting Kitchen (v1.20.0)
$$$$$$ Running command `terraform version`
       Terraform v0.11.6
       + provider.aws v1.14.0

$$$$$$ Terraform v0.11.6 is supported
-----> Setting up <default-example-infra>...
       Finished setting up <default-example-infra> (0m0.00s).
-----> Verifying <default-example-infra>...
       Verifying host '13.124.252.143' of group 'default'
       Loaded default

Profile: default
Version: (not specified)
Target:  ssh://ubuntu@13.124.252.143:22

  ✔  operating_system: Command lsb_release -a
     ✔  Command lsb_release -a stdout should match /Ubuntu/


Profile Summary: 1 successful control, 0 control failures, 0 controls skipped
Test Summary: 1 successful, 0 failures, 0 skipped
       Finished verifying <default-example-infra> (0m0.86s).
-----> Kitchen is finished. (0m2.56s)
```

테스트가 잘 수행되었다.

### kitchen destroy로 테스트 인프라 teardown

``` sh
$ kitchen destroy

# terraform destroy를 수행하고
# 이후 default workspace로 변경한 다음 테스트 워크스페이스도 제거한다.
```

### kitchen test

위의 과정을 모두 모은 숏컷인 `kitchen test` 커맨드가 있는데, 위 과정을 순서대로 진행한다.

``` sh
$ kitchen test

# create - converge - verify - destroy
:

```

## 마치며

`Infrastructure as code`라는 말은 단순히 코드로 인프라를 표현하는데 그쳐선 안된다고 생각이 들었다.

코드로 인프라를 표현해 보면서 패턴을 찾고, 모듈화와 추상화를 통해 효율적인 작업방식을 찾아
시스템으로 녹여내고, 계속 발전시켜 나가는데 의의가 있다고 생각한다.

테스트코드가 없는 오래된 비즈니스 로직은 유지보수가 힘든 만큼, 인프라도 동일하다고 생각한다.
쉽지 않겠지만.. 인프라도 테스트를 하며 레거시로 만들지 않기 위한 노력을 많이 해야 할 것 같다.

~그놈에 기술부채... ㅠㅠ~

## References

- [Outsider's Dev Story - Terraform에 대해서...](https://blog.outsider.ne.kr/1259)
- [test-kitchen, kitchen-ci](https://kitchen.ci/)
- [kitchen-terraform](https://newcontext-oss.github.io/kitchen-terraform/)
- [terraform workspace](https://www.terraform.io/docs/state/workspaces.html)
- [inspec](https://www.inspec.io/)

