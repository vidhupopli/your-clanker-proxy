# Dedicated ENI so we never get a second auto-assigned public IPv4, and so
# instance replace (user-data / dest-list changes) keeps the same EIP.
resource "aws_network_interface" "this" {
  subnet_id         = aws_subnet.public.id
  security_groups   = [aws_security_group.this.id]
  source_dest_check = true

  tags = {
    Name = "${var.name}-eni"
  }
}

resource "aws_eip" "this" {
  domain = "vpc"

  tags = {
    Name = "${var.name}-eip"
  }
}

resource "aws_eip_association" "this" {
  allocation_id        = aws_eip.this.id
  network_interface_id = aws_network_interface.this.id
}
