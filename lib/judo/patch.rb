module Aws
  class Ec2
    def describe_snapshots(list=[], opts={})
      params = {}
      params.merge!(hash_params('SnapshotId',list.to_a))
      params.merge!(hash_params('Owner', [opts[:owner]])) if opts[:owner]
      link = generate_request("DescribeSnapshots", params)
      request_cache_or_info :describe_snapshots, link,  QEc2DescribeSnapshotsParser, @@bench, list.blank?
    rescue Exception
      on_exception
    end
  end
end
