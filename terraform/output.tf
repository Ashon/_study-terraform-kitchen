output "public_ip" {
  value = "${aws_instance.test_compute.public_ip}"
}
