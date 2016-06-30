require 'jira'
require 'netrc'
require 'logger'

module Broker
  class JiraConnector

    attr_reader :client

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

    JIRA_HOST = 'jira.company.net'

    @@netrc = Netrc.read(ENV['HOME'] + "/.netrc")[JIRA_HOST]

    @@login = @@netrc['login']
    @@password = @@netrc['password']

    def self.client
      options = {
          :username => @@login,
          :password => @@password,
          :site     => 'https://' + JIRA_HOST,
          :context_path => '',
          :auth_type => :basic,
          # :use_ssl => false,
          :ssl_verify_mode => OpenSSL::SSL::VERIFY_NONE
      }

      @@client = JIRA::Client.new(options)
      @@client
    end

    def make_comment(issue_id, text)
      issue = JiraConnector.client.Issue.find(issue_id)
      comment = issue.comments.build
      body = {:'body' => "#{text}"}
      comment.save(body)
    end

    def make_transition(issue_id, transition_name_regex, issue_status_from = nil, comment = nil)
      issue = JiraConnector.client.Issue.find(issue_id)
      issue_status = issue.fields['status']['name'].downcase
      logger.info("Jira #{issue_id}: making transition: #{transition_name_regex} from status '#{issue_status_from}'...")
      t = Time.now
      begin
        transition_id = get_transition_id(issue, transition_name_regex)
        timeout = Time.now - t
      end while (transition_id.nil? && (timeout < 3))
      if (transition_id.nil? || (issue_status_from != nil && (issue_status != issue_status_from.downcase)) )
        logger.warn "Jira #{issue_id}: transition #{transition_name_regex} can't be done from status '#{issue_status_from}'. Wrong initial status: #{issue_status}"
        return false
      else
        transition = issue.transitions.build()
        transition.save(:transition => {:id => transition_id})
        logger.info("Jira #{issue_id}: made transition #{transition_name_regex} from status '#{issue_status_from}'.")
        unless comment.nil?
          make_comment(issue_id, comment)
        end
        true
      end
    end

    def get_transition_id(issue, transition_name_regex)
      issue.transitions.all.each do |i|
        if (i.name.downcase =~ /#{transition_name_regex.downcase}/)
          logger.debug "Jira #{issue.key}: found transition name: '#{i.name}' id: '#{i.id}'"
          return i.id
        end
      end
      # logger.warn("Jira #{issue.key}: can't find transition: #{transition_name_regex}")
      nil
    end

    def assignee_clean(issue_id)
      assignee_update(issue_id)
    end

    def assignee_update(issue_id, assignee_user = nil)
      logger.info "Jira #{issue_id}: update assignee to #{assignee_user}"
      issue = JiraConnector.client.Issue.find(issue_id)
      if assignee_user.nil?
        issue.save(:fields => {:assignee => nil} )
      else
        issue.save(:fields => {:assignee => {:name => assignee_user}} )
      end
    end

    def custom_field_update(issue_id, custom_field, cf_value = nil)
      issue = JiraConnector.client.Issue.find(issue_id)
      if issue.fields.has_key?(custom_field)
        result = issue.save(:fields => {custom_field => cf_value})
      end
      if result
        logger.info "Jira #{issue_id}: field #{custom_field} updated to #{cf_value}"
      else
        logger.error "Jira #{issue_id}: FAILED update #{custom_field} to #{cf_value}"
      end
    end

    def get_issue_type(issue_id)
      issue = JiraConnector.client.Issue.find(issue_id)
      issue.fields['issuetype']['name']
    end

  end

end