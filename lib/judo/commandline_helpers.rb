module JudoCommandLineHelpers
  def judo_yield(arg, blk)
    begin
      blk.call(arg)
    rescue JudoInvalid => e
      puts "#{arg} - #{e.message}"
    end
  end

  def split(string)
    if string =~  /([^:]*):(.*)/
      [ $1, $2 ]
    else
      [ string, nil] 
    end
  end

  def find_groups(judo, args, &blk)
    raise JudoError, "No groups specified" if args.empty? and judo.group.nil?

    args << ":#{judo.group}" if args.empty?  ## use default group if none specified

    groups = args.map do |arg|
      name,group = split(arg)
      raise JudoError, "specify a group with ':GROUP'" unless name == "" and group
      judo.get_group(group)
    end

    groups.each { |group| judo_yield(group, blk) if blk }
  end

  def mk_servers(judo, args, &blk)
    servers = args.map do |arg|
      name,group = split(arg)
      group ||= judo.group
      raise JudoError, "Cannot must specify a server, not a group, on create and launch" unless name
      if name =~ /^\+(\d+)/
        count = $1.to_i
        raise JudoError, "You can batch-create between 1 and 5 servers" if count < 1 or count > 5
        (1..count).map { judo.new_server(nil, group) }
      else
        judo.new_server(name, group)
      end
    end
    servers.flatten.each { |s| judo_yield(s, blk) if blk }
  end

  def find_either(judo, args, &blk)
    results = []
    args.each do |arg|
      server,group = split(arg)
      if server != ""
        results << judo.servers.select { |s| s.name == server }
      else
        results << judo.groups.select { |g| g.name == group }
      end
    end
    results.flatten.each { |i| judo_yield(i, blk) if blk }
  end

  def find_servers(judo, args, use_default = true, &blk)
    servers = judo.servers if args.empty?
    servers ||= args.map { |a| find_server(judo, a, use_default) }.flatten

    raise JudoError, "No servers" if servers.empty?

    servers.each { |s| judo_yield(s,blk) if blk }
    servers
  end

  def find_server(judo, arg, use_default = false)
    ## this assumes names are unique no matter the group
    name,group = split(arg)
    if name != ""
      server = judo.servers.detect { |s| s.name == name }
      raise JudoError, "No such server #{name}" unless server
      raise JudoError, "Server #{name} not in group #{group}" if group and server.group.name != group
      server
    else
      group ||= judo.group if use_default
      g = judo.groups.detect { |g| g.name == group }
      raise JudoError, "No such group #{group}" unless g
      g.servers
    end
  end

  def do_groups(judo)
    printf "  SERVER GROUPS\n"
    judo.groups.each do |g|
      printf "%-18s %s servers\n", g.name, g.servers.size
    end
  end

  def do_volumes(judo)
    vols = judo.volumes.sort { |a,b| [ a[:assigned_to].to_s, a[:instance_id].to_s ] <=> [ b[:assigned_to].to_s, b[:instance_id].to_s ] }

    format = "%13s %6s %12s  %-10s %-16s %-16s\n"
    printf format, "AWS_ID", "SIZE", "AWS_STATUS", "AWS_DEVICE", "ATTACHED TO", "CONFIGURED FOR"
    printf "%s\n", ("-" * 80)

    vols.each do |v|
      attached = v[:attached_to] ? v[:attached_to].name : v[:instance_id]
      assigned = v[:assigned_to] ? v[:assigned_to].name : ""
      printf format, v[:id], v[:size], v[:status], v[:device], attached, assigned
    end
  end

  def do_ips(judo)
    ips = judo.ips.sort { |a,b| a[:assigned_to].to_s <=> b[:assigned_to].to_s }

    format = "%15s %20s %20s\n"
    printf format, "IP", "ATTACHED TO", "CONFIGURED FOR"
    printf "%s\n", ("-"*57)

    ips.each do |ip|
      attached = ip[:attached_to] ? ip[:attached_to].name : ip[:instance_id]
      assigned = ip[:assigned_to] ? ip[:assigned_to].name : ""
      printf format, ip[:ip], attached, assigned
    end
  end

  def do_snapshots(judo, args)
    servers = find_servers(judo, args)
    printf "  SNAPSHOTS\n"
    printf "%s\n", ("-" * 80)
    ## FIXME - listing snapshots for deleted servers?
    judo.snapshots.each do |snapshot|
#      next if args and not servers.map { |s| s.name }.include?(snapshot.server_name)
      printf "%-15s %-25s %-15s %-10s %s\n", snapshot.name, snapshot.server_name, snapshot.group_name, snapshot.version_desc, "#{snapshot.num_ec2_snapshots}v"
    end
  end

  def do_list(judo, args)
    servers = find_servers(judo, args)
    printf "  SERVERS\n"
    printf "%s\n", ("-" * 80)
    servers.sort.each do |s|
      printf "%-32s %-12s %-7s %-11s %-11s %-10s %-3s %s\n", s.name, s.group.name, s.version_desc, s.state["instance_id"], s.size_desc, s.ec2_state, "#{s.volumes.keys.size}v", s.has_ip? ? "ip" : ""
    end
  end

  def do_info(judo, server)
    puts "#{server}"
    if server.ec2_instance and not server.ec2_instance.empty?
      puts "\t[ EC2 ]"
      [:aws_instance_id, :ssh_key_name, :aws_availability_zone, :aws_state, :aws_image_id, :dns_name, :aws_instance_type, :private_dns_name, :aws_launch_time, :aws_groups ].each do |k|
        printf "\t %-24s: %s\n",k, server.ec2_instance[k]
      end
    end
    puts "\t[ VOLUMES ]"
    server.ec2_volumes.each do |v|
      printf "\t %-13s %-10s %-10s %4d  %-10s %-8s\n",
      v[:aws_id],
      v[:aws_status],
      v[:zone],
      v[:aws_size],
      v[:aws_attachment_status],
      v[:aws_device]
    end
  end
end
