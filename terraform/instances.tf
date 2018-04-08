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
