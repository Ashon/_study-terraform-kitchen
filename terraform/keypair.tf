resource "aws_key_pair" "test_keypair" {
  key_name   = "test_keypair"
  public_key = "${var.test_keypair_public_key}"
}
