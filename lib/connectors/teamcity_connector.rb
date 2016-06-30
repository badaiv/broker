require 'teamcity'
require_relative '../utils'

module Broker
  class TeamCityConnector

    def logger
      unless defined? @logger
        ENV['LOGGER'].nil? ? (@logger  = Logger.new(STDOUT)) : (@logger  = Logger.new($root_path + ENV['LOGGER']))
        @logger.formatter = Logger::Formatter.new
        @logger.level = Logger::DEBUG
      end
      @logger
    end

    def logger=(logger)
      @logger = logger
    end

    TeamCity.configure do |config|
      config.endpoint = 'https://teamcity.company.net/guestAuth/app/rest/'
    end

    def get_issues_list(build_id)
      TeamCity.build_issues(build_id).map{ |i| i.id}.uniq
    end

    def get_change_issues(change_id)
      TeamCity.change_issues(id: change_id)
    end

    def get_issues_from_build(build_id)
      changes_list = TeamCity.changes(build: build_id) || {}
      changes_list_full = changes_list.map { |change| TeamCity.change(id: change.id)}
      issues = []
      changes_list_full.map { |change|
        change_issues = get_change_issues(change.id).issue
        change_issues = change_issues.map { |issue|
          issue.merge!(project_key: Utils.get_project_key(issue.id))
          issue.merge!(vcs_id: change.vcsRootInstance['vcs-root-id'])
        }
        issues = issues + change_issues
      }
      issues = remove_storm_vcs_roots(issues)
      issues.map{ |i| i.id}.uniq
    end

    def remove_storm_vcs_roots(issues)
      issues.select{ |change|  change.project_key == 'STRM' || (!(['StormDev', 'StormMaster'].include?(change.vcs_id)))}
    end

    def get_issue_list_between_builds(build_type, build_start, build_end)
      issues = []
      if (build_start.id != build_end.id)
        builds = TeamCity.builds_since(options = {buildType: build_type, status: 'SUCCESS'}, since_build_options = {id: build_start.id})
        select_builds = builds.select{ |build| (build.number.to_i <= build_end.number.to_i)}
      else
        select_builds = [build_start]
      end
      select_builds.each { |build| issues = issues + get_issues_from_build(build.id) }
      issues.uniq
    end

    def get_build_by_id(build_id)
      TeamCity.build(id: build_id)
    end

    def get_snapshot_build(build_id)
      build = get_build_by_id(build_id)
      raise "More then one snapshot dependencie" unless (build['snapshot-dependencies'].count !=  1)
      snapshot_build = build['snapshot-dependencies'].build[0]
      TeamCity.build(id: snapshot_build.id)
    end

    def get_previous_successful_build(build)
      builds = TeamCity.builds(buildType: build.buildTypeId, status: 'SUCCESS')
      builds.each_with_index do |b, i|
        if b.number.to_i <= build.number.to_i
          return get_build_by_id(builds[i].id)
        end
      end
      nil
    end

    def get_build_id_by_number(build_number)
      build = get_build_by_id(number: build_number)
      build.id
    end
  end

end

