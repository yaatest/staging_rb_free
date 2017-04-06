#!/usr/bin/env ruby

module Prox
 
  load             'conf'
  require          'colorize' 
  require          'proxmox'
  require_relative 'Read_vm_conf_by_name'  

  @conn = lambda {
    $prox = Proxmox::Proxmox.new(
      $prox_api,
      'node',
      $prox_user,
      $prox_pass,
      'pam',
      { verify_ssl: false }
    )
  }

  @report_status_err = lambda { puts "Some error occured. Trying to get status again..".red }
  @get_upid          = lambda { |oper_status_full| @oper_status_full = oper_status_full }
  
  def self.wait_while_finished(&block)
    @oper_status        = "running"
    while @oper_status != "stopped" do
      begin
        yield if block_given?
        @oper_status = @oper_status_full.fetch("status")
        case @oper_status
          when "running"
            puts "* in progress..".yellow
          when "stopped"
            puts "* finished".yellow
          else
            puts @oper_status
        end
      rescue
        @report_status_err.call
      end
      sleep 3
    end
  end

  def self.prox_get_nextid
    @conn.call
    @nextid = $prox.get("cluster/nextid") 
    return @nextid
  end  

  def self.create_clone(clone_name, clone_vmid = prox_get_nextid)
    @conn.call
    @clone_vmid = clone_vmid 
    puts "* Make vm clone #{@clone_vmid} from template #{$tmpl_id}".green
    clone_upid = $prox.post("nodes/#{$where_tmpl}/qemu/#{$tmpl_id}/clone",
      { :newid   => @clone_vmid,
        :name    => clone_name,
        :target  => $where_tmpl,
        :full    => 1, 
        :storage => $tmpl_storage,
        :format  => 'qcow2'
      })
    Prox::wait_while_finished{ @get_upid.call( $prox.get("nodes/#{$where_tmpl}/tasks/#{clone_upid}/status")) } 
  end 
 
  def self.configure_vm(vm_name)
    @conn.call
    mac         = Read_vm_conf_by_name.new(vm_name).vm_mac
    mem         = Read_vm_conf_by_name.new(vm_name).vm_ram
    cpu_cores   = Read_vm_conf_by_name.new(vm_name).vm_cpu_cores
    cpu_sockets = Read_vm_conf_by_name.new(vm_name).vm_cpu_sockets
    
    @iso = $iso ||= 'none,media=cdrom'
    
    puts "* Configure #{vm_name}.#{$domain}".green
    printf "* Set\n".green
    printf "%-30s %s\n", "mac:","#{mac}".blue
    printf "%-30s %s\n", "mem:","#{mem}".blue
    printf "%-30s %s\n", "cpu_cores:","#{cpu_cores}".blue
    printf "%-30s %s\n", "cpu_sockets:","#{cpu_sockets}".blue
    printf "%-30s %s\n", "iso:","#{@iso}".blue
    puts "* Waiting while vm configure task is stopped..".green
    configure_upid = $prox.post("nodes/#{$where_tmpl}/qemu/#{@clone_vmid}/config",
      { :memory      => mem,
        :sockets     => cpu_sockets,
        :cores       => cpu_cores,         
        :net0        => "virtio=#{mac},bridge=vmbr0",
        :description => $note,
        :cdrom       => @iso
      })
    Prox::wait_while_finished{ @get_upid.call( $prox.get("nodes/#{$where_tmpl}/tasks/#{configure_upid}/status")) }
  end

  def self.migrate_vm(vm, where_put_node, clone_vmid = @clone_vmid)
    @conn.call
    @where_put_node = where_put_node
    migrate_upid    = $prox.post("nodes/#{$where_tmpl}/qemu/#{@clone_vmid}/migrate", { :target => @where_put_node })
    puts "* Migrate #{vm}.#{$domain} to #{where_put_node}".green
    Prox::wait_while_finished{ @get_upid.call( $prox.get("nodes/#{$where_tmpl}/tasks/#{migrate_upid}/status")) }
    
    if vm.include?('st')
      puts "* Attach #{$swift_hdd_size} GB hdds for swift storage to #{vm}.#{$domain} on #{@where_put_node}".green
      
      swift_hdd_put_to = Read_vm_conf_by_name.new(vm).hv_hdd_to_put_vm
      add_swift_hdds   = $prox.put("nodes/#{@where_put_node}/qemu/#{@clone_vmid}/config",
        { :virtio2 => "#{swift_hdd_put_to}:#{$swift_hdd_size},format=qcow2",
          :virtio3 => "#{swift_hdd_put_to}:#{$swift_hdd_size},format=qcow2"
        })
    end 
  end

  def self.migrate_vm_hdd(vm, where_put_hdd, where_put_node = @where_put_node, clone_vmid = @clone_vmid)
    @conn.call
    puts "* Migrate #{vm}.#{$domain} hdd to #{@where_put_node}/#{where_put_hdd}".green
    migrate_hdd_upid = $prox.post("nodes/#{where_put_node}/qemu/#{@clone_vmid}/move_disk",
      { :storage => where_put_hdd, 
        :disk    => 'virtio0',
        :format  => 'qcow2',
        :delete  => 1,
      })
    Prox::wait_while_finished{ @get_upid.call( $prox.get("nodes/#{where_put_node}/tasks/#{migrate_hdd_upid}/status")) }
  end
  
  def self.create_staging_vms(vms)
    @conn.call
    vms.each do |vm|
      vm_conf = Read_vm_conf_by_name.new(vm)
      Prox::create_clone(vm_conf.vm_name)  
      Prox::configure_vm(vm)
      Prox::migrate_vm(vm, vm_conf.hv_to_put_vm_to)
      Prox::migrate_vm_hdd(vm, vm_conf.hv_hdd_to_put_vm)
      Prox::create_pool
      Prox::put_vm_to_pool
      Prox::start_vm 
    end
  end 

  def self.pool_exists?(domain = $domain)
    @conn.call
    @domain = domain
    result = $prox.get("pools/#{@domain}")
    
    if result.include?('NOK: error code = 500')
      puts "* Pool #{@domain} doesn't exist in cloud".green
      exist = false 
    else
      puts "* Pool #{@domain} exists in cloud".green
      exist = true
    end

    return exist 
  end

  def self.create_pool(domain = $domain)
    @conn.call
    @domain = domain
    puts "* Create pool #{@domain} if doesn't exist".green
    Prox::pool_exists? || ( puts "* Create pool #{@domain}".green
    $prox.post("pools", { :poolid => @domain }))
  end

  def self.put_vm_to_pool
    @conn.call
    puts "* Move vm #{@clone_vmid} to pool #{$domain}".green
    $prox.put("pools/#{$domain}", { :vms => @clone_vmid })
    vm_in_pool = false

    while not vm_in_pool.equal?(true) do
      begin
        vm_in_pool = Prox::vm_is_in_pool?(@clone_vmid)
      rescue
        @report_status_err.call
      end
      sleep 1
    end
  end

  def self.vm_is_in_pool?(vmid)
    @conn.call
    @vmid     = vmid.to_i
    poolinfo  = $prox.get("pools/#{$domain}")
    @pool_vms = Array.new
    poolinfo.fetch('members').each {|vm|  @pool_vms << vm.fetch('vmid')}
  
    if @pool_vms.include?(@vmid)
      puts "* VM #{@vmid} is in pool #{$domain}".green
      vm_in_pool = true
    else
      puts "* VM #{@vmid} isn't in pool #{$domain}".red
      vm_in_pool = false
    end
    return vm_in_pool
  end
  
  def self.start_vm(vm = @clone_vmid)
    @conn.call
    puts "* Starting vm #{@clone_vmid}".green
    vm_start_upid = $prox.post("nodes/#{@where_put_node}/qemu/#{@clone_vmid}/status/start") 
    Prox::wait_while_finished{ @get_upid.call( $prox.get("nodes/#{@where_put_node}/tasks/#{vm_start_upid}/status")) }
  end

  def self.get_hvs
    @conn.call
    hvs = $prox.get('nodes/').collect do |node|
      node.fetch("node")
    end
    return hvs
  end

  def self.get_nodes_statuses(nodes)
    @conn.call
    nodes_statuses = nodes.collect do |node|
      $prox.get("nodes/#{node}/status")
    end
  end

  def self.delete_vm(vmid, node)
    @conn.call

    puts "* Stop vmid #{vmid} on #{node}".green
    $prox.post("nodes/#{node}/qemu/#{vmid}/status/stop")
    Prox::wait_while_finished{ @get_upid.call( $prox.get("/nodes/#{node}/qemu/#{vmid}/status/current")) }

    puts "* Delete vmid #{vmid} from #{node}".green
    delete_vm_upid = $prox.delete("nodes/#{node}/qemu/#{vmid}")

    puts "* Waiting while delete task is stopped..".green
    Prox::wait_while_finished{ @get_upid.call( $prox.get("nodes/#{node}/tasks/#{delete_vm_upid}/status")) }
  end
  
  def self.delete_staging(domain = $domain)
    @conn.call
    puts "* Determine vms in pool #{$domain}".green
    pool = $prox.get("pools/#{domain}")
    Prox::pool_exists? && 
      ( pool.fetch('members').each do |vm|
         delete_vm("#{vm.fetch('vmid')}", "#{vm.fetch('node')}")
       end )
  end

  def self.delete_pool(domain = $domain)
    @conn.call
    puts "* Delete pool #{$domain} if exists".green
    Prox::pool_exists? && ( 
      puts "* Delete pool #{$domain}".green 
      $prox.delete("pools/#{domain}") 
    )
  end

end
