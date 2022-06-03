# encoding: utf-8

require 'katello_test_helper'
require 'support/host_support'

module Katello
  class HostManagedExtensionsTestBase < ActiveSupport::TestCase
    def setup
      disable_orchestration # disable foreman orchestration
      @dev = KTEnvironment.find(katello_environments(:dev).id)
      @library = KTEnvironment.find(katello_environments(:library).id)
      @view = ContentView.find(katello_content_views(:library_dev_staging_view).id)
      @library_view = ContentView.find(katello_content_views(:library_view).id)

      @foreman_host = FactoryBot.create(:host)
      @foreman_host.save!
    end
  end

  class HostManagedExtensionsTest < HostManagedExtensionsTestBase
    def test_update_organization
      host = FactoryBot.create(:host, :with_subscription)
      assert_raises ::Katello::Errors::HostRegisteredException do
        host.update(organization_id: ::Organization.find_by(name: "Empty Organization").id)
      end
    end

    def test_rhsm_fact_values
      assert_empty @foreman_host.rhsm_fact_values

      fv = FactValue.create!(value: 'something', host: @foreman_host, fact_name: RhsmFactName.create(name: 'some-fact'))

      assert_equal [fv], @foreman_host.rhsm_fact_values
    end

    def test_destroy_host
      assert @foreman_host.destroy
    end

    def test_full_text_search
      other_host = FactoryBot.create(:host)
      found = ::Host.search_for(@foreman_host.name)

      assert_includes found, @foreman_host
      refute_includes found, other_host
    end

    def test_host_status_reset
      host = FactoryBot.create(:host)
      host.host_statuses.delete_all
      Katello::SubscriptionStatus.create!(host: host, :status => Katello::SubscriptionStatus::VALID)
      host.reload
      assert_equal Katello::SubscriptionStatus::VALID, host.host_statuses.first.status
      host.reset_katello_status
      assert_equal Katello::SubscriptionStatus::UNKNOWN, host.host_statuses.first.status
    end

    def test_unknown_statuses_exists_in_katello_status_classes
      ::Katello::HostStatusManager::STATUSES.each do |status_class|
        assert status_class.const_defined?(:UNKNOWN), "Checking #{status_class.name}"
      end
    end

    def test_pools_expiring_in_days
      host_with_pool = FactoryBot.create(:host, :with_subscription)
      host_with_pool.subscription_facet.pools << FactoryBot.build(:katello_pool, :expiring_in_12_days, cp_id: 1, organization: host_with_pool.organization)
      assert_includes ::Host.search_for('pools_expiring_in_days = 30'), host_with_pool
    end

    def test_smart_proxy_ids_with_katello
      content_source = FactoryBot.create(:smart_proxy,
                                          :features => [Feature.where(:name => "Pulp Node").first_or_create])
      Support::HostSupport.attach_content_facet(@foreman_host, @view, @library)
      @foreman_host.content_facet.content_source = content_source
      assert_includes @foreman_host.smart_proxy_ids, @foreman_host.content_source_id
    end

    def test_info_with_katello
      assert_nil @foreman_host.info['parameters']['content_view']
      assert_nil @foreman_host.info['parameters']['lifecycle_environment']
      assert_equal @foreman_host.info['parameters']['foreman_host_collections'], []

      Support::HostSupport.attach_content_facet(@foreman_host, @view, @library)
      host_collection = katello_host_collections(:simple_host_collection)
      host_collection.hosts << @foreman_host

      assert_equal @foreman_host.info['parameters']['content_view'], @foreman_host.content_view.label
      assert_equal @foreman_host.info['parameters']['lifecycle_environment'], @foreman_host.lifecycle_environment.label
      assert_includes @foreman_host.info['parameters']['foreman_host_collections'], host_collection.name
    end

    def test_update_with_cv_env
      host = FactoryBot.create(:host, :with_content, :content_view => @library_view, :lifecycle_environment => @library)
      host.content_facet.content_view = @library_view
      host.content_facet.lifecycle_environment = @library
      assert host.content_facet.save!
    end

    def test_update_with_invalid_cv_env_combo
      host = FactoryBot.create(:host, :with_content, :content_view => @library_view, :lifecycle_environment => @library)
      host.content_facet.content_view = @library_view
      host.content_facet.lifecycle_environment = @dev
      assert_raises(ActiveRecord::RecordInvalid) do
        host.content_facet.save!
      end
    end
  end

  class HostManagedExtensionsUpdateTest < HostManagedExtensionsTestBase
    def test_update
      host = FactoryBot.create(:host, :with_content, :with_subscription, :content_view => @library_view, :lifecycle_environment => @library)
      host.content_facet.expects(:save!)
      params = {"facts" => {'memory.memtotal' => '16 GB'}}.with_indifferent_access
      host.subscription_facet.expects(:update_from_consumer_attributes).with(params)
      ::Katello::Resources::Candlepin::Consumer.expects(:update).with(host.subscription_facet.uuid, params)
      ::Katello::Resources::Candlepin::Consumer.expects(:refresh_entitlements).never
      ::Katello::Host::SubscriptionFacet.expects(:update_facts).with(host, params[:facts])
      host.update_candlepin_associations(params)
    end

    def test_update_with_autoheal
      host = FactoryBot.create(:host, :with_content, :with_subscription, :content_view => @library_view, :lifecycle_environment => @library)
      host.content_facet.expects(:save!)
      params = {:facts => {'memory.memtotal' => '16 GB'}, :autoheal => true}.with_indifferent_access
      assert_equal host.subscription_facet_attributes.autoheal, false

      ::Katello::Resources::Candlepin::Consumer.expects(:update).with(host.subscription_facet.uuid, params)
      ::Katello::Resources::Candlepin::Consumer.expects(:refresh_entitlements).with(host.subscription_facet.uuid)
      ::Katello::Host::SubscriptionFacet.expects(:update_facts).with(host, params[:facts])
      host.subscription_facet.expects(:update_hypervisor).with(params)
      host.subscription_facet.expects(:update_guests).with(params)

      host.update_candlepin_associations(params)

      assert_equal host.subscription_facet_attributes.autoheal, true
    end

    def test_update_with_false_autoheal
      host = FactoryBot.create(:host, :with_content, :with_subscription, :content_view => @library_view, :lifecycle_environment => @library)
      host.subscription_facet.update(autoheal: true)
      params = {:autoheal => false}.with_indifferent_access

      ::Katello::Resources::Candlepin::Consumer.expects(:update).with(host.subscription_facet.uuid, params)
      host.subscription_facet.expects(:update_hypervisor).with(params)
      host.subscription_facet.expects(:update_guests).with(params)

      host.update_candlepin_associations(params)

      assert_equal host.subscription_facet_attributes.autoheal, false
    end

    def test_update_with_nil_facts
      host = FactoryBot.create(:host, :with_content, :with_subscription, :content_view => @library_view, :lifecycle_environment => @library)
      host.content_facet.expects(:save!)
      params = {:facts => nil}.with_indifferent_access
      host.subscription_facet.expects(:update_from_consumer_attributes).with(params)
      ::Katello::Resources::Candlepin::Consumer.expects(:update).with(host.subscription_facet.uuid, params)
      ::Katello::Resources::Candlepin::Consumer.expects(:refresh_entitlements).never
      ::Katello::Host::SubscriptionFacet.expects(:update_facts).never
      host.update_candlepin_associations(params)
    end

    def test_update_without_subscription_facet
      host = FactoryBot.create(:host, :with_content, :content_view => @library_view, :lifecycle_environment => @library)
      host.content_facet.expects(:save!)
      params = {:facts => nil}.with_indifferent_access
      ::Katello::Resources::Candlepin::Consumer.expects(:update).never
      ::Katello::Resources::Candlepin::Consumer.expects(:refresh_entitlements).never
      ::Katello::Host::SubscriptionFacet.expects(:update_facts).never
      host.update_candlepin_associations(params)
    end

    def test_update_without_any_facet
      host = FactoryBot.create(:host, :content_view => @library_view, :lifecycle_environment => @library)
      params = {:facts => nil}.with_indifferent_access
      ::Katello::Resources::Candlepin::Consumer.expects(:update).never
      ::Katello::Resources::Candlepin::Consumer.expects(:refresh_entitlements).never
      ::Katello::Host::SubscriptionFacet.expects(:update_facts).never
      host.update_candlepin_associations(params)
    end

    def test_update_with_facet_params
      host = FactoryBot.create(:host, :with_content, :with_subscription, :content_view => @library_view, :lifecycle_environment => @library)
      host.content_facet.expects(:save!)
      host.subscription_facet.stubs(:consumer_attributes).returns('autoheal' => true)
      host.subscription_facet.expects(:update_from_consumer_attributes).with('autoheal' => true)
      ::Katello::Resources::Candlepin::Consumer.expects(:update).with(host.subscription_facet.uuid, host.subscription_facet.consumer_attributes)
      ::Katello::Resources::Candlepin::Consumer.expects(:refresh_entitlements).never
      ::Katello::Host::SubscriptionFacet.expects(:update_facts).never
      host.update_candlepin_associations
    end

    def test_backend_update_needed?
      host = FactoryBot.create(:host, :with_content, :with_subscription, :content_view => @library_view, :lifecycle_environment => @library)
      subscription_facet = host.subscription_facet
      refute subscription_facet.backend_update_needed?

      subscription_facet.service_level = 'terrible'
      assert subscription_facet.backend_update_needed?

      subscription_facet.reload
      refute subscription_facet.backend_update_needed?

      subscription_facet.host.content_facet.content_view_id = @view.id
      assert subscription_facet.backend_update_needed?
    end

    def test_backend_update_needed_purpose_addons?
      host = FactoryBot.create(:host, :with_content, :with_subscription, :content_view => @library_view, :lifecycle_environment => @library)
      subscription_facet = host.subscription_facet
      refute host.subscription_facet.backend_update_needed?

      subscription_facet.purpose_addon_ids = [katello_purpose_addons(:addon).id]
      assert host.subscription_facet.backend_update_needed?
    end

    def test_host_update_with_overridden_dmi_uuid
      ::Setting[:host_dmi_uuid_duplicates] = ['duplicate-dmi-uuid']
      params = {facts: {'dmi.system.uuid' => 'duplicate-dmi-uuid'}}.with_indifferent_access
      host = FactoryBot.create(:host, :with_content, :with_subscription, :content_view => @library_view, :lifecycle_environment => @library)
      host.subscription_facet.expects(:update_from_consumer_attributes).with(params)
      ::Katello::Resources::Candlepin::Consumer.expects(:update).with(host.subscription_facet.uuid, params)
      ::Katello::Resources::Candlepin::Consumer.expects(:refresh_entitlements).never
      ::Katello::Host::SubscriptionFacet.expects(:update_facts).with(host, params[:facts])
      host.update_candlepin_associations(params)
      override = host.subscription_facet.dmi_uuid_override
      assert_equal override.value, params[:facts]['dmi.system.uuid']
    end
  end

  class HostInstalledPackagesTest < HostManagedExtensionsTestBase
    def setup
      super
      package_json = {:name => "foo", :version => "1", :release => "1.el7", :arch => "x86_64", :epoch => "1",
                      :nvra => "foo-1-1.el7.x86_64", :vendor => "Fedora"}
      @foreman_host.import_package_profile([::Katello::Pulp::SimplePackage.new(package_json)])
      @nvra = 'foo-1-1.el7.x86_64'
      @foreman_host.reload
    end

    def test_installed_packages
      assert_equal 1, @foreman_host.installed_packages.count
      assert_equal 'foo', @foreman_host.installed_packages.first.name
      assert_equal @nvra, @foreman_host.installed_packages.first.nvra
      assert_equal 'Fedora', @foreman_host.installed_packages.first.vendor
    end

    def test_import_package_profile_adds_removes_bulk
      packages = [::Katello::Pulp::SimplePackage.new(:name => "betterfoo", :version => "1", :release => "1.el7",
                                                     :arch => "x86_64", :epoch => "1", :nvra => "betterfoo-1-1.el7.x86_64")]
      @foreman_host.import_package_profile(packages)
      assert_equal 1, @foreman_host.installed_packages.count
      assert_equal 'betterfoo', @foreman_host.installed_packages.first.name
      assert_equal 'betterfoo-1:1-1.el7.x86_64', @foreman_host.installed_packages.first.nvrea
      assert_equal '1', @foreman_host.installed_packages.first.epoch

      @foreman_host.reload
      packages << ::Katello::Pulp::SimplePackage.new(:name => "alphabeta", :version => "1", :release => "2", :arch => "x86_64",
                                                     :epoch => "1", :nvra => "alphabeta-1-2.x86_64")
      @foreman_host.import_package_profile(packages)
      assert_equal 2, @foreman_host.installed_packages.count
    end

    def test_search_installed_package
      assert_includes ::Host::Managed.search_for("installed_package = #{@nvra}"), @foreman_host
      assert_includes ::Host::Managed.search_for("installed_package_name = foo"), @foreman_host
    end
  end

  class HostEnabledReposTest < HostManagedExtensionsTestBase
    def test_import_repos
      repos_json = [{"repositoryid" => "good", "baseurl" => ["https://foo.com/pulp/content/foo"]},
                    {"repositoryid" => "bad", "baseurl" => []}]
      Support::HostSupport.attach_content_facet(@foreman_host, @view, @library)
      @foreman_host.content_facet.expects(:update_repositories_by_paths).with(["/pulp/content/foo"])
      @foreman_host.import_enabled_repositories(repos_json)
    end
  end

  class HostAvailableModulesTest < HostManagedExtensionsTestBase
    def make_module_json(name = "foo", status = "unknown", context = nil, installed_profiles = [], active = nil)
      {
        "name" => name,
        "stream" => "8",
        "version" => "20180308143646",
        "context" => context,
        "arch" => "x86_64",
        "profiles" => [
          "development",
          "minimal",
          "default"
        ],
        "installed_profiles" => installed_profiles,
        "status" => status,
        "active" => active
      }
    end

    def test_import_modules
      modules_json = [
        make_module_json("enabled-installed", "enabled", 'blahcontext', ["default"]),
        make_module_json("enabled2", "enabled"),
        make_module_json("disabled", "disabled", "abacadaba"),
        make_module_json("unknown", "unknown")
      ]
      @foreman_host.import_module_streams(modules_json)
      assert_equal 1, @foreman_host.host_available_module_streams.installed.size
      assert_equal 2, @foreman_host.host_available_module_streams.enabled.size
      assert_equal 1, @foreman_host.host_available_module_streams.disabled.size
      assert_equal 1, @foreman_host.host_available_module_streams.unknown.size

      installed_params = modules_json.first

      installed = @foreman_host.host_available_module_streams.installed.first
      assert_equal installed_params["name"], installed.available_module_stream.name
      assert_equal installed_params["stream"], installed.available_module_stream.stream
      assert_equal installed_params["installed_profiles"], installed.installed_profiles
      assert_equal "enabled", installed.status
      refute_empty installed.installed_profiles

      assert_equal 'abacadaba', @foreman_host.host_available_module_streams.disabled.first.available_module_stream.context
    end

    def test_import_modules_with_active_field
      modules_json = [
        make_module_json("enabled-varying-activity", "enabled", "12347", [], true),
        make_module_json("enabled-varying-activity", "enabled", "12345", [], false),
        make_module_json("enabled-varying-activity", "enabled", "12346", [], false)
      ]

      @foreman_host.import_module_streams(modules_json)

      assert_equal "12347", @foreman_host.host_available_module_streams.enabled.first.available_module_stream.context
      assert_equal 1, @foreman_host.host_available_module_streams.enabled.count
      assert_equal "12345", @foreman_host.host_available_module_streams.unknown.min_by(&:id).available_module_stream.context
      assert_equal "12346", @foreman_host.host_available_module_streams.unknown.max_by(&:id).available_module_stream.context
      assert_equal 2, @foreman_host.host_available_module_streams.unknown.count
    end

    def test_import_modules_with_update
      modules_json = [make_module_json("enabled21111", "enabled")]
      prior_count = HostAvailableModuleStream.count
      @foreman_host.import_module_streams(modules_json)
      assert_equal prior_count + 1, HostAvailableModuleStream.count
      assert_equal "enabled", @foreman_host.reload.host_available_module_streams.first.status

      modules_json.first["status"] = "unknown"

      @foreman_host.import_module_streams(modules_json)
      assert_equal "unknown", @foreman_host.reload.host_available_module_streams.first.status
      assert_equal prior_count + 1, HostAvailableModuleStream.count

      @foreman_host.import_module_streams([])
      assert_empty @foreman_host.reload.host_available_module_streams
      assert_equal prior_count, HostAvailableModuleStream.count

      @foreman_host.import_module_streams([make_module_json("xxxx", "enabled", 'blah', ["default"])])
      assert_equal "enabled", @foreman_host.reload.host_available_module_streams.first.status
      assert_equal ["default"], @foreman_host.reload.host_available_module_streams.first.installed_profiles

      @foreman_host.import_module_streams([make_module_json("xxxx", "enabled", 'blah', [])])
      assert_equal "enabled", @foreman_host.reload.host_available_module_streams.first.status
      assert_empty @foreman_host.reload.host_available_module_streams.first.installed_profiles
    end
  end

  class HostTracerTest < HostManagedExtensionsTestBase
    def setup
      super
      tracer_json = {
        "sshd": {
          "type": "daemon",
          "helper": "sudo systemctl restart sshd"
        },
        "tuned": {
          "type": "daemon",
          "helper": ""
        }
      }
      @foreman_host.import_tracer_profile(tracer_json)
      @foreman_host.reload
    end

    def test_trace_blank_helper
      assert_empty @foreman_host.host_traces.where(application: 'tuned')
    end

    def test_known_traces
      assert_equal 1, @foreman_host.host_traces.count
      assert_equal 'sshd', @foreman_host.host_traces.first.application
    end

    def test_search_known_traces
      assert_includes ::Host::Managed.search_for("trace_app_type =  daemon"), @foreman_host
      assert_includes ::Host::Managed.search_for("trace_app = sshd"), @foreman_host
      assert_includes ::Host::Managed.search_for("trace_helper = \"sudo systemctl restart sshd\""), @foreman_host
    end
  end

  class HostManagedExtensionsKickstartTest < ActiveSupport::TestCase
    def setup
      disable_orchestration # disable foreman orchestration
      @distro = katello_repositories(:fedora_17_x86_64)
      @os = ::Redhat.create_operating_system('RedHat', '17', '0')
      @os.stubs(:kickstart_repos).returns([@distro])
      @arch = architectures(:x86_64)
      @distro_cv = @distro.content_view
      @distro_env = @distro.environment
      @content_source = FactoryBot.create(:smart_proxy,
                                          name: "foobar",
                                          url: "http://example.com/",
                                          lifecycle_environments: [@distro_env])
      @medium = FactoryBot.create(:medium, operatingsystems: [@os])

      @host = FactoryBot.create(:host, operatingsystem: @os, arch: @arch)
      Support::HostSupport.attach_content_facet(@host, @distro_cv, @distro_env)
      @host.content_facet.content_source = @content_source
      @host.save!
    end

    def test_set_medium
      @host.medium = @medium
      assert_valid @host
      assert_equal @host.medium, @medium
    end

    def test_set_installation_medium
      @host.content_facet.kickstart_repository = @distro
      assert_valid @host
      assert_equal @host.content_facet.kickstart_repository, @distro
    end

    def test_change_medium_to_kickstart_repository
      @host.medium = @medium
      assert @host.save

      @host.content_facet.kickstart_repository = @distro
      assert_valid @host
      assert_nil @host.medium
      assert_equal @host.content_facet.kickstart_repository, @distro
    end

    def test_change_kickstart_repository_to_medium
      @host.content_facet.kickstart_repository = @distro
      assert @host.save

      @host.medium = @medium
      assert_valid @host
      assert_nil @host.content_facet.kickstart_repository
      assert_equal @host.medium, @medium
    end

    def test_change_os_from_facts_without_ks_repo
      @host.content_facet.kickstart_repository = @distro
      assert @host.save

      os = Redhat.new(:name => 'Zippity Do Da', :major => '9')
      @host.operatingsystem = os
      @host.send(:update_os_from_facts)
      assert_nil @host.content_facet.kickstart_repository
    end

    def test_change_os_from_facts_with_ks_repo
      @host.content_facet.kickstart_repository = @distro
      assert @host.save

      ::Redhat.any_instance.stubs(:kickstart_repos).returns([{id: @distro.id}])
      os = Redhat.new(:name => 'Zippity Do Da', :major => '9')
      @host.operatingsystem = os
      @host.send(:update_os_from_facts)

      assert_equal @host.operatingsystem, os
      assert_equal @host.content_facet.kickstart_repository, @distro
    end
  end
end
