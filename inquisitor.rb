#!/usr/bin/env ruby
#
# The Release Inquisition
#
# NOBODY expects the Spanish Inquisition! Our chief weapon is surprise...
# surprise and fear... fear and surprise.... Our two weapons are fear and
# surprise... and ruthless efficiency.... Our *three* weapons are fear,
# surprise, and ruthless efficiency... and an almost fanatical devotion to the
# Pope.... Our *four*... no... *Amongst* our weapons.... Amongst our
# weaponry... are such elements as fear, surprise.... I'll come in again.

require 'jira'
require 'colored'
require 'json'

# Utility to retrieve command line input
# @param noecho [Boolean, nil] if we are retrieving command line input with or without privacy. This is mainly
#   for sensitive information like passwords.
def get_input(echo = true)
  fail "Cannot get input on a noninteractive terminal" unless $stdin.tty?

  system 'stty -echo' unless echo
  $stdin.gets.chomp!
ensure
  system 'stty echo'
end

def usage
  usage = <<-EOD
Usage: #{File.basename($0)} [path to git repo] [JIRA project] [start commit] [end commit] [JIRA version]

Examples:
    # Set up credentials for interacting with JIRA
    export JIRA_USERNAME='adrien'
    export JIRA_PASSWORD='hunter2'

    # Inquire about all commits between the 2.0.2 tag and the latest commit of
    # the current branch, and compare against issues with a fixVersion of '2.1.0'
    # in the FACT project.
    #{File.basename($0)} ~/src/facter FACT 2.0.2 HEAD 2.1.0"
    #
    # Inquire about all commits between the 3.6.2 tag and the 'master' branch,
    # and compare against issues with a fixVersion of '3.7.0' in the PUP project.
    #{File.basename($0)} ~/src/puppet PUP 3.6.2 master 3.7.0"
  EOD

  $stderr.puts usage
end

def parse_commitlog(path, from, to, project)
  commitlog = nil
  Dir.chdir(path) do
    commitlog = %x{git log --no-merges --oneline #{from}..#{to}}
  end

  committed_issues = Hash.new {|h, k| h[k] = [] }
  commitlog.each_line do |line|
    commit = {:issue => 'unmarked'}
    issue = 'unmarked'

    project_regex = /^[\[\(](#{project}-\d+)[\]\)]/i
    note_regex = /^[\[\(](\w+)[\]\)]/

    sha, rest = line.split(/\s+/, 2)
    commit[:sha] = sha

    if (m = rest.match(/#{project_regex}\s+(.*)$/i))
      issue = commit[:issue] = m[1]
      commit[:msg] = m[2]
    elsif (m = rest.match(/#{note_regex}\s+(.*)$/))
      issue = commit[:issue] = m[1]
      commit[:msg] = m[2]
    else
      commit[:msg] = rest
    end

    committed_issues[issue] << commit
  end

  committed_issues
end

def fetch_jira_issues(client, project, fixversion)
  q = %Q(project = #{project} and fixVersion = '#{fixversion}')

  begin
    known_issues = JIRA::Resource::Issue.janql(client, q).inject({}) do |hash, issue|
      hash[issue.key] = {
        :summary    => issue.attrs['fields']['summary'],
        :resolution => issue.attrs['fields']['resolution'],
      }
      hash
    end
  rescue JIRA::HTTPError => e
    errors = JSON.parse(e.response.body)['errorMessages']
    $stderr.puts "Could not query JIRA: #{e.code} #{e.message} #{errors.inspect}"
    exit 1
  end

  known_issues
end

if !ENV['JIRA_USERNAME']
  $stderr.puts "Error: JIRA_USERNAME environment variable must be set"
  usage
  exit 1
end

if ARGV.count != 5
  $stderr.puts "Error: Wrong number of arguments"
  usage
  exit 1
end

path = ARGV[0]
project = ARGV[1]
from = ARGV[2]
to = ARGV[3]
fixversion = ARGV[4]

jira_site = 'https://tickets.puppetlabs.com'
puts "Logging in to #{jira_site} as #{ENV['JIRA_USERNAME']}"
print "Password please: "
jira_password = get_input(false)
puts

client = JIRA::Client.new(
  :username => ENV['JIRA_USERNAME'],
  :password => jira_password,
  :site => jira_site,
  :context_path => '',
  :use_ssl => true,
  :auth_type => :basic)


# Add in a method for querying JIRA with a manually specified maxResults parameter.
# Makes you feel dirty, don't it? It should.
class JIRA::Resource::Issue
  def self.janql(client, jql)
    url = client.options[:rest_base_path] + "/search?jql=" + CGI.escape(jql)
    url += "&maxResults=1000"
    response = client.get(url)
    json = parse_json(response.body)
    json['issues'].map do |issue|
      client.Issue.build(issue)
    end
  end
end

known_issues = fetch_jira_issues(client, project, fixversion)
committed_issues = parse_commitlog(path, from, to, project)

puts "++ Issues committed in this release"
only_git_issues = []
committed_issues.keys.sort.each do |k|
  if known_issues[k.upcase]
    marker = '--'
    color = :green
  else
    only_git_issues << k
    color = :yellow
    marker = '**'
  end
  puts "  #{marker} #{k.upcase}".send(color)
  v = committed_issues[k]
  v.each do | data |
    puts "    #{data[:commit]}  #{data[:msg]}"
  end
end

puts
puts "++ Issues without an issue reference"
only_git_issues.sort.each do |issue|
  next unless issue == 'unmarked'
  committed_issues[issue].each do |commit|
    puts "    #{commit[:sha]}: #{commit[:msg]}"
  end
end

puts
puts "++ Issues in Git that are not in Jira"
only_git_issues.sort.each do |issue|
  next if %w[maint doc packaging unmarked].include? issue
  puts "    #{issue}"
  committed_issues[issue].each do |commit|
    puts "      #{commit[:sha]}: #{commit[:msg]}"
  end
end

not_in_jira = committed_issues.select { |k, v| (%w[maint doc] & v.map { |x| x[:issue] }).empty? and ! known_issues[k]}.sort { |a, b| a[0] <=> b[0] }

puts
puts "++ Issues in Jira not found in Git"
(known_issues.keys - (committed_issues.keys & known_issues.keys)).each do |key|
  msg = known_issues[key][:summary]
  res = known_issues[key][:resolution] || {'name' => 'Unresolved'.cyan}
  puts "    #{key}: (#{res['name']}) #{msg}"
end
