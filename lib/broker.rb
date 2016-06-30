require 'grape'
require_relative 'connectors/github_connector'
require_relative 'connectors/jira_connector'
require_relative 'connectors/teamcity_connector'
require_relative 'repos_configuration'
require_relative 'utils'


module Broker
  class API < Grape::API
    version 'v1', using: :header, vendor: 'twitter'
    format :json
    prefix :api

    HOTFIX = %w(Hotfix Hotfix-s)
    FEATURE = %w(Feature Feature-s Bugfix Bugfix-s)
    ISSUE_TYPES = ['New Feature', 'Bug', 'Improvement', 'Task', 'Sub-Task (engineering)']
    FIELD_FLAG_OPEN_PULL_REQUEST = 'customfield_11014'
    FIELD_REPOS = 'customfield_11011'
    FIELD_BRANCH_ORIGINAL = 'customfield_11010'
    FIELD_BRANCH_BASE = 'customfield_11008'

    DEV_BRANCH = 'dev'
    PREPROD_BRANCH = 'preprod'
    MASTER_BRANCH = 'master'

    GITHUB_SYSTEM_USER = 'srvc-broker'

    BACK_TO_PROGRESS = 'Back to In Progress'
    MERGED = '^merge'

    resource :branch do
      desc 'Create branch.'
      post do
        jira_branch_create(params)
      end
    end

    resource :branch_delete do
      desc 'Delete branch.'
      post do
        jira_branch_delete(params)
      end
    end

    resource :pullrequest do
      desc 'Create Pull Request.'
      post do
        jira_pullrequest_create(params)
      end
    end

    resource :deployment do
      desc 'Move issues after deployment.'
      post do
        jira_transition_issues(params)
      end
    end

    resource :github_event_handler do
      desc 'Listener for github events.'
      post do
        if monitored_repo?(params.repository.full_name)
          case request.env['HTTP_X_GITHUB_EVENT']
            when 'pull_request'
              pull_request = params['pull_request']
              if params['action'] == 'closed'
                if monitored_issue_type?(pull_request['title'])
                  issue_id = Utils. get_issue_id(pull_request['title'])
                  logger.info "GitHub #{issue_id}: #{params.repository.full_name} pull_request #{params['action']} ##{pull_request['number']} '#{pull_request['title']}'"
                  process_pull_request_close(pull_request, issue_id)
                end
              end
            when 'push'
              push = params
              commits = push.commits.map{|commit| commit.id}
              logger.debug "GitHub #{push.repository[:full_name]}: push to #{push['ref']} by #{push.sender['login']}, commits: #{commits}" unless commits.empty?
              #catching push to protected branch
              if push_to_protected_branch?(push)
                #todo action on this push
                logger.warn "GitHub #{push.repository[:full_name]}: Direct Push to '#{push[:ref]}' by '#{push.sender[:login]}' sha:#{push[:after]} compare url: '#{push[:compare]}'"
              end
          end
        end
      end
    end

    helpers do
      def logger
        ENV['LOGGER'].nil? ? (@logger  = Logger.new(STDOUT)) : (@logger  = Logger.new($root_path + ENV['LOGGER']))
        @logger
      end

      def jira_transition_issues(payload)
        tc = TeamCityConnector.new
        build = payload.build
        deploy_build_id = build.buildId
        deploy_build = tc.get_build_by_id(deploy_build_id)
        env_prop = deploy_build.properties.property.select{|prop| prop.name == 'deploy.env'}[0]
        unless env_prop.nil?
          logger.info "TeamCity: #{build.buildFullName} ##{deploy_build.number} : deploy with id #{build.buildId}"
          deploy_env = env_prop.value
          release_build = tc.get_snapshot_build(deploy_build_id)
          previous_deploy_build = tc.get_previous_successful_build(deploy_build)
          previous_release_build = tc.get_snapshot_build(previous_deploy_build.id)
          logger.info "TeamCity: #{build.buildFullName} ##{deploy_build.number} : deploy releases starting from build number #{previous_release_build.number}"
          issue_list = tc.get_issue_list_between_builds(release_build.buildTypeId, previous_release_build, release_build)
          logger.info "TeamCity: #{build.buildFullName} ##{deploy_build.number} : deploying issues \" #{issue_list.join(', ')} \""
          jira = JiraConnector.new
          if (deploy_env == 'beta' or deploy_env == 'preprod')
            issue_list.each do |issue_id|
              comment = "[*#{deploy_build.buildType.projectId}* Build|#{deploy_build.webUrl}] was successfully deployed to #{deploy_env}. Issue was moved to deployed status."
              jira.make_transition(issue_id, '^deploy', "merged_to_#{deploy_env}", comment)
            end
          end
        else
          logger.warn "TeamCity: #{build.buildFullName} - #{build.buildTypeId} ##{build.buildNumber} : not a deploy build type : id - #{build.buildId}"
        end
      end

      def jira_branch_delete(transition)
        issue = transition[:issue]
        issue_id = issue[:key]
        branch_name = issue_id + '-' + issue.fields.summary
        #to get all available repos, set FIELD_REPOS to nil
        issue.fields[FIELD_REPOS] = nil
        repos = get_repos_from_issue(issue)
        logger.info "Jira #{issue_id}: deleting all branches"
        repos.each do |repo|
          gh = GitHubConnector.new(repo)
          response = gh.branch_delete(branch_name)
        end
        jira = JiraConnector.new
        jira.custom_field_update(issue_id,FIELD_FLAG_OPEN_PULL_REQUEST)
        jira.make_comment(issue_id, "#{params.user['displayName']} *deleted* all branches for #{issue_id}.")
      end

      def get_repos_from_issue(issue)
        # check if 'all repos' selected
        repos_in_issue = issue.fields[FIELD_REPOS]
        # if no branch selected, set up all branches
        unless (repos_in_issue)
          repos_in_issue = [{:value => 'all Inflection'}]
        end
        all_org = repos_in_issue.select{|x| x[:value].include?('all')}
        repos_by_org = []
        unless (all_org.empty?)
          all_org = all_org.map{|repo| repo[:value].scan(/\w+$/).last}
          all_org.each do |organisation|
            repos_by_org = repos_by_org + Utils.get_full_repos_by_org(organisation)
          end
        end
        repos_in_issue_single = repos_in_issue.select{|x| !x[:value].include?('all')}
        repos_single = repos_in_issue_single.map{ |repo| $REPOSITORIES[repo[:value]] + '/' + repo[:value] }
        repos = repos_single + repos_by_org
        #always create branch in storm repo
        repos << 'Inflection/storm'
        repos.uniq
      end

      def push_to_protected_branch?(push)
        #catching direct push to master, dev, preprod branches from users
        ref = push['ref'].sub('refs/heads/','')
        return false if (push.deleted == true)
        ((ref == MASTER_BRANCH) or (ref == DEV_BRANCH) or (ref == PREPROD_BRANCH)) \
            && !push.head_commit.message.include?('Merge pull request') && push.pusher['name'] != GITHUB_SYSTEM_USER \
            && monitored_repo?(push.repository['full_name'])
      end

      def monitored_repo?(repo)
        repo = Utils.get_repo_from_full_repo(repo)
        $REPOSITORIES.has_key?(repo)
      end

      def monitored_issue_type?(issue_name)
        issue_id = Utils.get_issue_id(issue_name)
        jira = JiraConnector.new
        issue_type = jira.get_issue_type(issue_id)
        return true if (HOTFIX.include?(issue_type) || FEATURE.include?(issue_type) || ISSUE_TYPES.include?(issue_type))
        false
      end

      def monitored_project?(issue_name)
        project_key = Utils.get_project_key(issue_name)
        $PROJECTS.has_key?(project_key)
      end

      def process_pull_request_close(pull_request, issue_id)
        #porcess only merged pull requests
        if pull_request['merged'] == true
          base_ref = pull_request.base['ref']
          head_sha = pull_request.head['sha']
          head_ref = pull_request.head['ref']
          repo = pull_request.base.repo['full_name']
          gh = GitHubConnector.new(repo)
          if (base_ref == 'master') or (base_ref == 'preprod')
            #merge PR also to DEV branch
            begin
              logger.debug "GitHub #{issue_id}: branch #{head_ref} merging into #{DEV_BRANCH}"
              gh.branch_merge(DEV_BRANCH, head_sha, "Merge branch #{head_ref}  into dev after pull request ##{pull_request['number']} was merged to 'master'")
              logger.info "GitHub #{issue_id}: branch #{head_ref} merged into #{DEV_BRANCH}"
            rescue Octokit::Conflict => e
              #if auto merge is failing raise PR
              begin
                logger.info "GitHub #{issue_id}: merging to #{DEV_BRANCH} failed. Creating PR from #{head_ref} into #{DEV_BRANCH}"
                dev_pull_request = gh.pull_request_create(DEV_BRANCH, head_ref)
                #assign PR to person who merged initial PR to master or preprod branch
                #TODO this part not working
                # last_commit = pull_request.head['sha']
                # last_commiter = gh.pull_request_last_commiter(last_commit)
                # number = dev_pull_request['number']
                # logger.info "GitHub #{issue_id}: assign pull request ##{number} to #{last_commiter}"
                # gh.pull_request_assignee(number, last_commiter)
              rescue Octokit::UnprocessableEntity => e
                logger.debug "Github #{issue_id}: #{e.inspect}"
              end
              logger.debug "Github #{issue_id}: #{e.inspect}"
            end
          end
          check_all_pull_requests(pull_request)
        end
      end

      def check_all_pull_requests(pull_request)
        repo = pull_request.base.repo['full_name']
        gh = GitHubConnector.new(repo)
        jira = JiraConnector.new
        head_ref = pull_request.head['ref']
        head_label = pull_request.head['label']
        issue_id = Utils.get_issue_id(head_ref)
        # elastic search working with delay, may return not full list of open PRs
        # rest_of_prs = gh.pull_request_search_open_elastic(issue_id)
        rest_of_prs = gh.pull_request_search_open(head_label)
        comment =''
        pr_number = pull_request['number']
        comment += "[pull request *#{pull_request['number']}*|#{pull_request['html_url']}] *closed* \n"
        rest_of_prs.each do |pr|
          comment += "[pull request *#{pr['number']}*|#{pr['html_url']}] into '*#{pr.base['ref']}*' left\n"
        end

        if rest_of_prs.empty?
          jira.custom_field_update(issue_id,FIELD_FLAG_OPEN_PULL_REQUEST)
          logger.info "GitHub #{issue_id}: Final pull request closed. Make transition 'Merge to ...'"
          unless jira.make_transition(issue_id, MERGED, 'in_manager_review')
            jira.make_transition(issue_id, 'To Manager Review')
            jira.make_transition(issue_id, MERGED, 'in_manager_review')
          end
          comment += "Final pull request closed. Issue moved to Merged"
        end
        jira.make_comment(issue_id, comment)
      end

      def jira_branch_create(transition)
        issue = transition[:issue]
        issue_id = issue[:key]
        head_branch = issue[:key] + '-' + issue.fields.summary
        logger.info "Jira #{issue_id}: create branches for issue: \"#{head_branch}\""
        jira = JiraConnector.new
        comment = "#{params.user['displayName']} creating branches : #{Utils.normalise_string(head_branch)}\n"
        #todo make default master for QA Automation
        base_branch = issue.fields[FIELD_BRANCH_ORIGINAL]
        repos = get_repos_from_issue(issue)
        repos.each do |repo|
          gh = GitHubConnector.new(repo)
          begin
            #TODO assert base_branch not null
            branch = gh.branch_create_from(base_branch, head_branch)
            weburi = branch.attrs[:url].sub('api/v3/repos/','').sub('git/refs/heads','tree')
            #todo make tab formatter
            comment += "#{repo.sub('/','/*')}*: new [branch|#{weburi}] from '*#{base_branch}*'\n"
            #todo do we need these comments?
          rescue Octokit::Error => e
            # comment += "#{repo}: Branch not created from #{base_branch}: #{e.message}\n"
          rescue ArgumentError => e
            comment += "#{repo.sub('/','/*')}*: branch #{e.message} *already exists*\n"
          end
        end
        jira.make_comment(issue_id, comment)
      end

      def jira_pullrequest_create(transition)
        issue = transition[:issue]
        head_branch = issue[:key] + '-' + issue.fields.summary
        head_branch = Utils.normalise_string(head_branch)
        issue_id = issue[:key]
        logger.info "Jira #{issue_id}: Create pull request for issue: \"#{head_branch}\""
        jira = JiraConnector.new
        comment = "#{params.user['displayName']} created pull requests:\n"
        base_branch = issue.fields[FIELD_BRANCH_BASE]
        repos = get_repos_from_issue(issue)
        flag_prs_not_mergable = false
        flag_open_pr = false
        repos.each do |repo|
          gh = GitHubConnector.new(repo)
          begin
            pull_request = gh.pull_request_create(base_branch,head_branch)
            flag_open_pr = true
            weburi = pull_request.attrs[:html_url]
            pr_number = pull_request['number']
            comment += "#{repo.sub('/','/*')}*: [pull request *#{pr_number}*|#{weburi}] created into '*#{base_branch}*'\n"
            pull_request_mergeable = gh.pull_request_mergable_wait(pull_request['number'])
            if !pull_request_mergeable
              flag_prs_not_mergable = true
              #todo improve comment
              comment += "#{repo.sub('/','/*') + '*'}: PR *#{pull_request['number']}* is not mergeable. Moving ticket to 'In Progress'\n"
            end
          rescue Octokit::Error => e
            # comment += "#{repo}: PullRequest not created: #{e.errors[0][:message]} \n"
          rescue ArgumentError => e
            # comment += "#{repo}: PullRequest not created: #{e.message} \n"
          end
        end
        if flag_open_pr
          jira.custom_field_update(issue[:key], FIELD_FLAG_OPEN_PULL_REQUEST, 'True')
          jira.make_transition(issue[:key], BACK_TO_PROGRESS) if flag_prs_not_mergable
        else
          comment += '*no changes* were found in branches'
        end
        jira.make_comment(issue[:key], comment)
      end
    end
  end
end
