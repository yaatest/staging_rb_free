#!/usr/bin/env ruby

module Dhcp
  
  require          'git'
  require          'securerandom'
  require          'fileutils' 
  require          'colorize'
  require_relative 'Ssh'
  include          Ssh

  def self.clone_dhcp_repo
    @domain = $domain
    @tmpid = SecureRandom.hex
    @dhcpd_tmpdir = "tmp/#{@tmpid}"
    puts "* Create tmp directory".green
    Dir.mkdir(@dhcpd_tmpdir)
    puts "* Clone dhcpd repo".green
    @dhcpd_repo = Git.clone("#{$dhcpd_git_url}", 'dhcpd', :path => @dhcpd_tmpdir)
    @dhcpd_repo.config('user.name', 'Rundeck')
    @dhcpd_repo.config('user.email', 'yaa@yaatest.ru')
    @domain_str = "include"+" "+"\"/etc/dhcp/dhcpd.includes/#{@domain}.conf\";\n"
    @path = "#{@dhcpd_tmpdir}/dhcpd"
    @dhcpd_conf_path = "#{@path}/dhcpd.conf"
  end

  def self.add_files_to_dhcpd_repo(domain)
    @dhcpd_repo.add(@dhcpd_conf_path.split('/').last)
    @dhcpd_repo.add("dhcpd.includes/#{@dhcpd_include.split('/').last}")
  end

  def self.commit_dhcpd_repo(action)
    @action = action
    puts "* Committing..".green
    @dhcpd_repo.commit_all("#{@domain} #{@action}")
    @dhcpd_repo.push
  end
  
  def self.remove_dhcpd_conf(domain)
    @domain = domain
    f_r = File.open(@dhcpd_conf_path, 'r')
    f_w = File.open("#{@dhcpd_conf_path}_new", 'w')

    f_r.each_line do |line|
      f_w.write(line) if ! line.include?(@domain_str)
    end
    f_r.close
    f_w.close
    puts "* Removing string \'#{@domain_str.chomp}\' from dhcpd.conf".green
    FileUtils.mv("#{@dhcpd_conf_path}_new", @dhcpd_conf_path )

    puts "* Removing include file: dhcpd.includes/#{@domain}.conf".green
    FileUtils.rm_rf("#{@path}/dhcpd.includes/#{@domain}.conf")
  end 

  def self.del_dhcp_repo
    puts "* Remove tmp directory".green
    FileUtils.rm_rf(@dhcpd_tmpdir)
  end

  def self.check_dhcpd_conf(domain)
    @domain = domain
    f = File.open(@dhcpd_conf_path, 'r')
    exist = false
    f.each_line do |line|
      exist = true if line.include? @domain_str 
    end
    f.close
    return exist
  end

  def self.append_dhcp_conf(domain)
    @domain = domain
    f = File.open(@dhcpd_conf_path, 'a')
    f << @domain_str
    f.close
  end

  def self.gen_dhcpd_include(vm, domain)
    @include =  <<HERE
host #{vm}.#{domain} { 
  option domain-name-servers #{$dns};
  hardware ethernet #{Read_vm_conf_by_name.new(vm).vm_mac};  
  fixed-address #{Read_vm_conf_by_name.new(vm).vm_ip};
  option domain-search "#{domain}";
  option host-name "#{vm}.#{domain}";
}

HERE
    return @include
  end

  def self.create_include_file(vms, domain)
    @vms = vms
    @domain = domain
    @vms.each do |vm|
    @dhcpd_include = "#{@path}/dhcpd.includes/#{@domain}.conf"
      f = File.open(@dhcpd_include, 'a')
      f << self.gen_dhcpd_include(vm, @domain)
      f.close 
    end
  end      

  def self.update_dhcpd
    Dhcp::clone_dhcp_repo
    if $delete == false
      Dhcp::check_dhcpd_conf($domain) || 
    ( Dhcp::append_dhcp_conf($domain)  
      Dhcp::create_include_file($vms, $domain) &&  
      Dhcp::add_files_to_dhcpd_repo($domain) &&
      Dhcp::commit_dhcpd_repo('added')
    )
    else
      Dhcp::check_dhcpd_conf($domain) && 
      Dhcp::remove_dhcpd_conf($domain) &&
      Dhcp::commit_dhcpd_repo('deleted')
    end
    Dhcp::del_dhcp_repo
    tmp_id_dhcpd = SecureRandom.hex
    tmp_dir_dhcpd = "/tmp/#{tmp_id_dhcpd}"
    n = Ssh::Run_via_ssh.new('gw1.nct')
    n.run_cmd_single_until_done("git clone #{$dhcpd_git_url} #{tmp_dir_dhcpd}")
    n.run_cmd_single_until_done("cp -av #{tmp_dir_dhcpd}/dhcpd.conf /etc/dhcp/dhcpd.conf.new")
    n.run_cmd_single_until_done("cp -av #{tmp_dir_dhcpd}/dhcpd.includes /etc/dhcp/dhcpd.includes.new")

    n.run_cmd_single_until_done("rm -fr /etc/dhcp/dhcpd.conf.old")
    n.run_cmd_single_until_done("rm -fr /etc/dhcp/dhcpd.includes.old")
    
    n.run_cmd_single_until_done("mv /etc/dhcp/dhcpd.conf /etc/dhcp/dhcpd.conf.old")
    n.run_cmd_single_until_done("mv /etc/dhcp/dhcpd.includes /etc/dhcp/dhcpd.includes.old")

    n.run_cmd_single_until_done("mv /etc/dhcp/dhcpd.conf.new /etc/dhcp/dhcpd.conf")
    n.run_cmd_single_until_done("mv /etc/dhcp/dhcpd.includes.new /etc/dhcp/dhcpd.includes")
 
    n.run_cmd_single_until_done("rm -fr #{tmp_dir_dhcpd}")
    n.run_cmd_single_until_done("service dhcpd restart")
  end

end
