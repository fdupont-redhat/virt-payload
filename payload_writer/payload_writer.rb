require 'date'
require 'sinatra'
require "sinatra/namespace"
require "sinatra/streaming"

require_relative 'classes'
require_relative 'utils'
require_relative 'api_methods'
require_relative 'create_methods'

TEST_URI       = "https://inventory-openshift-migration.apps.cluster-pmcgow.v2v.bos.redhat.com".freeze
VMS            = "/vms?detail=1".freeze
HOSTS          = "/hosts?detail=1".freeze
CLUSTERS       = "/clusters?detail=1".freeze
PROVIDERS      = "/providers?detail=1".freeze
FOLDERS        = "/folders".freeze
NAMESPACES     = "/namespaces".freeze
TOPOLOGY       = "/tree/host".freeze

$debug         = true
$stdout.sync   = true

# ----

def process_vc(vcenter)
  clusters      = {}
  ems           = create_ems(vcenter)
  vc_link       = vcenter['selfLink']
  @folder_paths = get_folder_paths(BASE_URI, vc_link + FOLDERS)

  get_mappings(BASE_URI, vc_link + TOPOLOGY)

  retrieve(BASE_URI, vc_link + CLUSTERS).each do |cluster|
    clusters[cluster['id']] = cluster
    ems.ems_clusters << create_cluster(cluster, @cluster_dc_map[cluster['id']])
  end
  
  retrieve(BASE_URI, vc_link + HOSTS).each do |host|
    ems.hosts << create_host(host, @host_cluster_map[host['id']])
  end

  retrieve(BASE_URI, vc_link + VMS).each.with_index(1) do |vm, id|
    ems.vms << create_vm(vm, id, @vm_host_map[vm['id']], clusters)
  end
  ems
end

# ----

def extract(provider_list)
  puts "Requested providers: #{provider_list.inspect}"
  all_vcenters = []
  get_namespaces(BASE_URI, NAMESPACES).each do |namespace|
    get_vsphere_providers(BASE_URI + "/namespaces", namespace, PROVIDERS).each do |vcenter|
      puts "Considering: #{namespace}/#{vcenter['name']}"
      next unless provider_list.include?("#{namespace}/#{vcenter['name']}")
      begin
        all_vcenters << process_vc(vcenter)
      rescue RestClient::Exception => err
        puts "The API request to the inventory database failed with code: #{err.response.code}" unless err.response.nil?
        puts "The response body was:\n#{err.response.body.inspect}" unless err.response.nil?
        next
      end
    end
  end
  
  payload = {
    "data_collected_on": "#{Time.now.utc}",
    "schema": {
      "name": "Mtv"
    },
    "manifest": {
      "manifest": {
        "version": "1.0.0"
      }
    },
    "ManageIQ::Providers::Vmware::InfraManager": all_vcenters
  }
  tgzfile = ""
  if $debug
    require 'memory_profiler'
    report = MemoryProfiler.report do
      tgzfile = package(payload.to_json)
    end
    puts "temp file is #{tgzfile}"
    report.pretty_print
  else
    tgzfile = package(payload.to_json)
  end
  tgzfile
end

# ----

# ------------- Main ---------------------

if FileTest.exist?("/var/run/secrets/kubernetes.io/serviceaccount/namespace")
  # Running in OpenShift
  BASE_URI  = "http://inventory".freeze
else
  BASE_URI  = TEST_URI
end

set :bind, '0.0.0.0'
set :port, 8080

namespace '/api/v1' do
  get '/extract' do
    begin
      raise "Must include a '?providers=namespace1/provider1,namespace2/provider2,...' parameter list" if request.fullpath.split('?')[1].nil?
      provider_list = request.fullpath.split('?')[1].split('providers=')[1].split(',')
      send_file extract(provider_list), :disposition => :attachment, :filename => 'mtv_payload.tar.gz'
    rescue => err
      puts "Error: [#{err}]"
    end
  end
end
