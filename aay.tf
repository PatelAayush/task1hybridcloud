//Describing Provider
provider "aws" {
  region  = "ap-south-1"
  profile = "aayush"
}


//Creating Variable for AMI_ID
variable "ami_id" {
  type    = string
  default = "ami-0447a12f28fddb066"
}


//Creating Variable for AMI_Type
variable "ami_type" {
  type    = string
  default = "t2.micro"
}

//Creating Key
resource "tls_private_key" "aay_key" {
  algorithm = "RSA"
}


//Generating Key-Value Pair
resource "aws_key_pair" "test_key" {
  key_name   = "web-env-key"
  public_key = "${tls_private_key.aay_key.public_key_openssh}"


  depends_on = [
    tls_private_key.aay_key
  ]
}


//Saving Private Key PEM File
resource "local_file" "key-file" {
  content  = "${tls_private_key.aay_key.private_key_pem}"
  filename = "web-env-key.pem"


  depends_on = [
    tls_private_key.aay_key
  ]
}

//Creating Security Group
resource "aws_security_group" "firewall" {
  name        = "firewall"
  description = "Web Environment Security Group"


  //Adding Rules to Security Group 
  ingress {
    description = "SSH Rule"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }


  ingress {
    description = "HTTP Rule"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

//Creating a S3 Bucket
resource "aws_s3_bucket" "aay1234" {
  bucket = "web-static-data-bucket"
  acl    = "public-read"
}

//Putting Objects in S3 Bucket
resource "aws_s3_bucket_object" "object" {
  bucket = "${aws_s3_bucket.aay1234.bucket}"
  key    = "image.jpeg"
  source = "image.jpeg"
  acl    = "public-read"
}

//Creating CloutFront with S3 Bucket Origin
resource "aws_cloudfront_distribution" "mycf" {
  origin {
    domain_name = "${aws_s3_bucket.aay1234.bucket_regional_domain_name}"
    origin_id   = "${aws_s3_bucket.aay1234.id}"
  }


  enabled             = true
  is_ipv6_enabled     = true
  comment             = "S3 Web Distribution"


  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "${aws_s3_bucket.aay1234.id}"


    forwarded_values {
      query_string = false


      cookies {
        forward = "none"
      }
    }


    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }


  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["IN"]
    }
  }


  tags = {
    Name        = "Web-CF-Distribution"
    Environment = "Production"
  }


  viewer_certificate {
    cloudfront_default_certificate = true
  }


  depends_on = [
    aws_s3_bucket.aay1234
  ]
}

//Launching EC2 Instance
resource "aws_instance" "myos" {
  ami             = "${var.ami_id}"
  instance_type   = "${var.ami_type}"
  key_name        = "${aws_key_pair.test_key.key_name}"
  security_groups = ["${aws_security_group.firewall.name}","default"]


  //Labelling the Instance
  tags = {
    Name = "Web-Env"
    env  = "Production"
  }


  //Put CloudFront URLs in our Website Code
  provisioner "local-exec" {
    command = "sed -i 's/url/${aws_cloudfront_distribution.mycf.domain_name}/g' index.html"
  }
  
  //Copy our Wesite Code i.e. HTML File in Instance Webserver Document Rule
  provisioner "file" {
    connection {
      agent       = false
      type        = "ssh"
      user        = "ec2-user"
      private_key = "${tls_private_key.aay_key.private_key_pem}"
      host        = "${aws_instance.myos.public_ip}"
    }


    source      = "index.html"
    destination = "/home/ec2-user/index.html" 
  }




  //Executing Commands to initiate WebServer in Instance Over SSH 
  provisioner "remote-exec" {
    connection {
      agent       = "false"
      type        = "ssh"
      user        = "ec2-user"
      private_key = "${tls_private_key.aay_key.private_key_pem}"
      host        = "${aws_instance.myos.public_ip}"
    }
    
    inline = [
      "sudo yum install httpd -y",
      "sudo systemctl start httpd",
      "sudo systemctl enable httpd",
    ]

  }


  //Storing Key and IP in Local Files
  provisioner "local-exec" {
    command = "echo ${aws_instance.myos.public_ip} > public-ip.txt"
  }


  depends_on = [
    aws_security_group.firewall,
    aws_key_pair.test_key
  ]
}

//Creating EBS Volume
resource "aws_ebs_volume" "web-vol" {
  availability_zone = "${aws_instance.myos.availability_zone}"
  size              = 1
  
  tags = {
    Name = "ebs-vol"
  }
}


//Attaching EBS Volume to a Instance
resource "aws_volume_attachment" "ebs_att" {
  device_name  = "/dev/sdh"
  volume_id    = "${aws_ebs_volume.web-vol.id}"
  instance_id  = "${aws_instance.myos.id}"
  force_detach = true


  provisioner "remote-exec" {
    connection {
      agent       = "false"
      type        = "ssh"
      user        = "ec2-user"
      private_key = "${tls_private_key.aay_key.private_key_pem}"
      host        = "${aws_instance.myos.public_ip}"
    }
    
    inline = [
      "sudo mkfs.ext4 /dev/xvdh",
      "sudo mount /dev/xvdh /var/www/html/",
      "sudo cp /home/ec2-user/index.html /var/www/html/"
    ]
  }


  depends_on = [
    aws_instance.myos,
    aws_ebs_volume.web-vol
  ]
}

//Creating EBS Snapshot
resource "aws_ebs_snapshot" "ebs_snapshot" {
  volume_id   = "${aws_ebs_volume.web-vol.id}"
  description = "Snapshot of our EBS volume"
  
  tags = {
    env = "Production"
  }


  depends_on = [
    aws_volume_attachment.ebs_att
  ]
}
