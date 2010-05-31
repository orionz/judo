module JudoCommandLineHelpers

  def each_server(judo, args, &blk)
    raise JudoError, "No servers specified - use :all for all servers" if args.empty?
    servers = judo.find_servers_by_name_or_groups(args)
    servers.each do |server|
      begin
        blk.call(server)
      rescue JudoInvalid => e
        puts "#{server} - #{e.message}"
      end
    end
  end

  def mk_server_names(judo, args, &blk)
    args.each do |arg|
      name,group = arg.split(":")
      raise JudoError, "You must specify a group on create and launch" unless group
      names = if name =~ /^[12345]$/ 
        (1..(name.to_i)).each do 
          blk.call(judo.mk_server_name(group), group)
        end
      elsif name == ""
        blk.call(judo.mk_server_name(group), group)
      elsif name =~ /^\d+$/ 
        raise JudoError, "You can batch-create between 1 and 5 servers" if count < 1 or count > 5
      else
        blk.call(name, group)
      end
    end
  end

  def mk_groups(judo, args, &blk)
    args.each do |name|
      if name =~ /:(.+)$/
        blk.call(Judo::Group.new(judo, $1))
      else
        raise JudoError, "Invalid group name '#{name}'"
      end
    end
  end

  def mk_servers(judo, options, args, start)
    mk_server_names(judo, args) do |name, group|
      begin
        server = judo.create_server(name, group, options)
        server.start(options) if start
      rescue JudoInvalid => e
        puts "#{server} - #{e.message}"
      end
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
    printf "  SNAPSHOTS\n"
    printf "%s\n", ("-" * 80)
    judo.snapshots.each do |snapshot|
      printf "%-15s %-25s %-15s %-10s %s\n", snapshot.name, snapshot.server_name, snapshot.group_name, snapshot.version_desc, "ebs:#{snapshot.ec2_ids.size}"
    end
  end

  def do_list(judo, args)
    printf "  SERVERS\n"
    printf "%s\n", ("-" * 80)
    args << ":all" if args.empty?
    each_server(judo,args) do |s|
      printf "%-32s %-12s %-7s %-11s %-11s %-10s %-3s %s\n", s.name, s.group.name, s.version_desc, s.get("instance_id"), s.size_desc, s.ec2_state, "ebs:#{s.volumes.keys.size}", s.has_ip? ? "ip" : ""
    end
  end

  def sub_info(header, data, &block)
    return if data == []
    return if data == {}
    return if data.nil?
    puts "  [ #{header} ]"
    [ data ].flatten.each do |d|
      block.call(d)
    end
  end

  def do_info(judo, server)
    puts "[ #{server} ]"
    printf "    %-24s: %s\n", "ID", server.id
    printf "    %-24s: %s\n", "Group", server.group.name
    printf "    %-24s: %s\n", "Note", server.note if server.note
    printf "    %-24s: %s\n", "Animated From", server.clone if server.clone
    printf "    %-24s: %s\n", "Elastic Ip", server.elastic_ip if server.elastic_ip
    sub_info("EC2", server.ec2_instance) do |i|
      [:aws_instance_id, :ssh_key_name, :aws_availability_zone, :aws_state, :aws_image_id, :dns_name, :aws_instance_type, :private_dns_name, :aws_launch_time, :aws_groups ].each do |k|
        printf "    %-24s: %s\n",k, i[k]
      end
    end
    sub_info("METADATA", server.metadata.keys) do |key|
      printf("    %-24s: %s\n", key, server.metadata[key] )
    end
    sub_info("VOLUMES", server.ec2_volumes) do |v|
      printf "    %-13s %-10s %-10s %4d  %-10s %-8s\n",
      v[:aws_id],
      v[:aws_status],
      v[:zone],
      v[:aws_size],
      v[:aws_attachment_status],
      v[:aws_device]
    end
    sub_info("SNAPSHOTS", server.snapshots) do |s|
      printf "    %-10s %-15s %-8s %-5s\n", s.name, s.group_name, s.version_desc, "#{s.ec2_ids.size}v"
    end
  end
end
