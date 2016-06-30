require 'octokit'
require 'logger'
require_relative '../repos_configuration'
require_relative '../utils'

module Broker
  class GitHubConnector

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

    def initialize(repo)
      #debug enable block
      stack = Faraday::RackBuilder.new do |builder|
        builder.response :logger
        builder.use Octokit::Response::RaiseError
        builder.adapter Faraday.default_adapter
      end
      #uncomment to enable debug logging
      # Octokit.middleware = stack

      # logger.debug "User for GitHub conenction: #{GitHubConnector.client.login}"
      @repo = repo
    end

    def self.client
      @@client ||= Octokit::Client.new(
          :api_endpoint => 'https://github.company.net/api/v3/',
        :web_endpoint => 'https://github.company.net',
        :netrc => true,
        # :netrc_file => './.netrc',
        :connection_options => {:ssl => { :verify => false }},
        :auto_paginate => true)
      @@client
    end

    def branch_merge(base, head, comment = {})
      GitHubConnector.client.merge(@repo, base, head, {:commit_message => comment})
    end

    def pull_request_assignee(number, assignee)
      GitHubConnector.client.update_issue(@repo, number, :assignee => assignee)
    end

    def pull_request_mergeable(number)
      pr = GitHubConnector.client.pull_request(@repo,number)
      pr['mergeable']
    end

    def pull_request_close(number)
      GitHubConnector.client.close_pull_request(@repo,number)
    end

    def pull_request_mergable_wait(number)
      logger.info("pull request ##{number}: waiting for mergeable status...")
      until !pull_request_mergeable( number).nil?
        sleep 0.1
      end
      pull_request_mergeable(number)
    end

    def branch_create_from(base_branch,name)
      nname = Utils.normalise_string(name)
      issue_id = Utils. get_issue_id(name)
      bcheck = branch_exist(nname)
      if (!bcheck) or (bcheck.nil?)
        begin
          sha = GitHubConnector.client.ref(@repo,"heads/#{base_branch}")[:object][:sha]
          response = GitHubConnector.client.create_ref(@repo,"heads/#{nname}", sha)
          logger.info "GitHub #{issue_id}: #{@repo} Branch created from #{base_branch}: #{nname}"
          return response
        rescue Octokit::Error => e
          logger.warn "GitHub #{issue_id}: #{@repo} Can't create branch from #{base_branch}: \"#{nname}\""
          logger.warn e.message.inspect
          raise e
        end
      else
        logger.warn "GitHub #{issue_id}: #{@repo} Branch with issue KEY already exist: #{bcheck}"
        raise ArgumentError, "#{bcheck}"
      end
    end

    def branch_delete(name)
      nname = Utils.normalise_string(name)
      branch = branch_exist(nname)
      issue_id = Utils.get_issue_id(name)
      unless branch.nil?
        begin
          response = GitHubConnector.client.delete_ref(@repo,"heads/#{branch}")
          logger.info "GitHub #{issue_id}: #{@repo} branch deleted : '#{nname}'"
        rescue Octokit::Error => e
          logger.warn "GitHub #{issue_id}: #{@repo} can't delete branch: '#{nname}'"
          logger.warn "GitHub #{issue_id}: #{e.message.inspect}"
        end
      end
    end

    def branch_exist(name)
      branch_key = Utils.get_issue_id(name) || name
      branches = GitHubConnector.client.refs(@repo,'heads')
      branches.each_with_index do |br, index|
        br_name = br[:ref].sub('refs/heads/','')
        br_key = Utils.get_issue_id(br_name) || br_name
        return br_name if (branch_key == br_key)
      end
      nil
    end

    def pull_request_create(base, head)
      nhead = Utils.normalise_string(head)
      title = branch_exist(nhead)
      issue_id = Utils.get_issue_id(head)
      if !title.nil?
        begin
          pull_request = GitHubConnector.client.create_pull_request(@repo, base, title, title)
          logger.info "GitHub #{issue_id}: #{@repo} pull request ##{pull_request[:number]} created: '#{title}', #{pull_request[:html_url]}"
          return pull_request
        rescue Octokit::Error => e
          if e.message.inspect.include?('A pull request already exists for')
            pr = pull_request_search_open_current_repo(title).first
            logger.debug "GitHub #{issue_id}: pull request already exists for head: '#{title}' - #{pr['html_url']} "
            return pr
          end
          unless e.message.inspect.include?('No commits between')
            logger.warn "GitHub #{issue_id}: #{@repo} can't create pull request from branch: '#{title}'"
            logger.debug "GitHub #{issue_id}: #{e.message.inspect}"
          end
          raise e
        end
      else
        logger.error "GitHub #{issue_id}: #{@repo} Branch doesn't exists: #{nhead}"
        raise ArgumentError, "Branch doesn't exists: #{nhead}"
      end
    end

    def pull_request_last_commiter(sha)
      response = GitHubConnector.client.commit(@repo, sha)
      response.author['login']
    end

    def pull_request_search_closed(name)
      response = GitHubConnector.client.search_issues("#{name} in:title is:closed type:pr")
      response.items || nil
    end

    def pull_request_search_unmerged(name)
      response = GitHubConnector.client.search_issues("#{name}  in:title is:pr is:unmerged repo:#{@repo} ")
      response.items || nil
    end

    def pull_request_search_open(head_label)
      issue_id = Utils.get_issue_id(head_label)
      pull_requests = []
      repos = Utils.get_full_repos_in_same_org(@repo)
      repos.each do |r|
        response = GitHubConnector.client.pull_requests(r, :state => 'open', :head => head_label)
        unless response.empty?
          response.each do |pr|
            logger.debug "GitHub #{issue_id}: pull request ##{pr['number']} found: #{pr['html_url']}"
          end
          pull_requests += response
        end
      end
      pull_requests || nil
    end

    def pull_request_search_open_current_repo(head)
      head_label = @repo.scan(/^\w+/).first + ':' + head
      issue_id = Utils.get_issue_id(head)
      response = GitHubConnector.client.pull_requests(@repo, :state => 'open', :head => head_label)
      response.each do |pr|
        logger.debug "GitHub #{issue_id}: pull request  ##{pr['number']} found: #{pr['html_url']}"
      end
      response || nil
    end

    def pull_request_search_open_elastic(name)
      issue_id = Utils.get_issue_id(name)
      response = GitHubConnector.client.search_issues("#{name} in:title state:open type:pr")
      unless response.items.empty?
        response.items.each do |pr|
          logger.debug "GitHub #{issue_id}: pull request  ##{pr['number']} found: #{pr['html_url']}"
        end
      end
      response.items || nil
    end

  end
end


