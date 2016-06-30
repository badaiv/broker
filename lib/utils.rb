module Broker
  class Utils

    def self.get_issue_id(name)
      key = name.scan(/^\w+[- ]\d+/).first
      return key.sub(' ','-') unless key.nil?
    end

    def self.get_project_key(name)
      project_key = name.scan(/^\w+/).first
      return project_key
    end

    def self.get_repo_from_full_repo(full_name)
      full_name.sub(/^\w+\//,'')
    end

    def self.get_full_repos_in_same_org(full_name)
      repo = get_repo_from_full_repo(full_name)
      organisation = $REPOSITORIES[repo]
      repos = $REPOSITORIES.select{|rep, org| org == organisation}
      repos.map{|r, org| org + '/' + r}
    end

    def self.get_full_repos_by_org(organisation)
      repos = $REPOSITORIES.select{|rep, org| org == organisation}
      repos.map{|r, org| org + '/' + r}
    end

    def self.normalise_string(name)
      nname = name.gsub(/[[\(\)\{\}\[\]\.,;:"'<>~\^\\]\\\/#&\*`!\$%\+=\?@\|]+/,'')
      nname = nname.gsub(' ','_')
      nname = nname.gsub(/[_]+$/,'')
      nname.match(/.{,30}/).to_s
      # nname.downcase
    end

  end
end
