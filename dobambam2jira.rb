require 'active_support/core_ext/hash'
require 'json'
require 'set'
require 'rest_client'
require 'html2confluence'
require 'slop'

class DoBamBam
  def initialize(base_uri, login, password)
    base_uri += '/' unless base_uri.end_with?('/')
    @base_uri = base_uri
    @login = login
    @password = password
  end

  def login
    unless @session_id
      result = RestClient.post("#{@base_uri}login",
                    login: @login,
                    password: @password) do |response, request, result, &block|
        response
      end
      @session_id = result.cookies['SLS2_SESSIDv4']
    end
  end

=begin
  def milestones(project_id)
    return @milestones[project_id] if @milestones && @milestones.has_key?(project_id)

    @milestones ||= {}

    login
    main_page = RestClient.get("#{@base_uri}project/#{project_id}", {cookies: {'SLS2_SESSIDv4' => @session_id}})
    m = /\\"milestones\\":(\[.+?\])/.match(main_page.to_s)
    @milestones[project_id] = JSON.parse(JSON.parse('{"data": "' + m[1] + '"}')['data'])
  end
=end

  def tasks(project_id, &block)
    return @project_tasks[project_id] if @project_tasks && @project_tasks.has_key?(project_id)

    login
    result = RestClient.post("#{@base_uri}ajax/request-method.json",
                  { method: 'Tasks:getTasks',
                   'report[id]' => 'reportName=All',
                   'report[name]' => 'All',
                   'report[projectId]' => project_id,
                   'report[myReport]' => 'false',
                   'report[status]' => 'PRIVATE',
                   'report[counters][all][toMe]' => 0,
                   'report[counters][all][all]' => 0,
                   'report[counters][unread][toMe]' => 0,
                   'report[counters][unread][all]' => 0,
                   'report[counters][starred][toMe]' => 0,
                   'report[counters][starred][all]' => 0,
                   'report[builtin]' => 'false',
                   'report[type]' => 'dynamic',
                   'report[parentId]' => '',
                   'report[filters][PROJECT]' => 'false',
                   'report[filters][OPENED_BY_USER]' => 'false',
                   'report[filters][ASSIGNED_TO_USER]' => 'false',
                   'report[filters][LABELS]' => 'false',
                   'report[filters][MILESTONE]' => 'false',
                   'report[filters][PRIORITY]' => 'false',
                   'report[filters][STATUS]' => 'false',
                   'report[filters][UPDATE_DATE]' => 'false',
                   'report[filters][DUE_DATE]' => 'false',
                   'report[filters][LIST]' => 'false',
                   'report[filters][CONTENT_FILTER]' => 'false',
                   'report[layout][listingType]' => 'LIST',
                   'report[layout][reportLayoutMode]' => 'COLUMNS',
                   'report[layout][sortBy]' => 'ID',
                   'report[layout][sortDir]' => 'ASC'
                  },
                  {cookies: {'SLS2_SESSIDv4' => @session_id}})
    data = JSON.parse(result)

    @project_tasks ||= {}

    result = {}
    data['result'].each do |t|
      ticket = fetch_ticket(project_id, t['id'], t['relativeId'])
      result[ticket['id']] = ticket
      yield ticket
    end

    @project_tasks[project_id] = result
  end

  def projects
    return @projects if @projects

    login
    result = RestClient.get("#{@base_uri}ajax/request-method.json?method=Account%3AgetProjectStats",
                  {cookies: {'SLS2_SESSIDv4' => @session_id}})
    data = JSON.parse(result)
    data = JSON.parse(data['result'])

    bambam_projects = []
    data['projects'].each do |p|
      project = self.project(p['id'])['result']
      next if project['name'] == 'BamBam! Tutorial'
      bambam_projects.append project
    end

    @projects = bambam_projects
  end

  def project(id)
    login
    result = RestClient.get("#{@base_uri}ajax/fetch-category.json?projectId=#{id}&withChildren=0&withBubbles=0&withBreads=0&messageSort=&messageFilter=&visibilityFilter=ALL&type=&status=")
    JSON.parse(result)
  end

  def users
    return @users if @users

    login
    main_page = RestClient.get("#{@base_uri}people", {cookies: {'SLS2_SESSIDv4' => @session_id}})
    m = /\\"users\\":(\[.+?\])/.match(main_page.to_s)
    arr = JSON.parse(JSON.parse('{"data": "' + m[1] + '"}')['data'])
    @users = {}
    arr.each {|el| @users[el['id']] = el}
    @users
  end

  def fetch_ticket(project_id, task_id, task_relative_id)
    login
    result = RestClient.get("#{@base_uri}ajax/fetch-ticket.html?ticketId=#{task_id}&projectId=#{project_id}&relativeId=#{task_relative_id}",
                               {cookies: {'SLS2_SESSIDv4' => @session_id},
                                verify_ssl: OpenSSL::SSL::VERIFY_NONE})
    JSON.parse(result)['ticket']
  end

  def fetch_ticket_followers(ticket_id, project_id)
    login
    result = RestClient.post("#{@base_uri}followers/list",
                            {type: 'TICKET', param: ticket_id, projectId: project_id},
                            {cookies: {'SLS2_SESSIDv4' => @session_id},
                             verify_ssl: OpenSSL::SSL::VERIFY_NONE})
    ids = JSON.parse(result)['result']
    user_info = users
    ids.map {|id| user_info[id]}
  end

  def fetch_attachment_url(h)
    @attachment_urls ||= {}
    return @attachment_urls[h] if @attachment_urls[h]

    login
    result = RestClient.get("#{@base_uri}file/download?fileId=#{h}",
                            {cookies: {'SLS2_SESSIDv4' => @session_id},
                             verify_ssl: OpenSSL::SSL::VERIFY_NONE}) do |response, request, result, &block|
      response
    end
    @attachment_urls[h] = result.headers[:location]
  end
end

def download_from_bambam(url, login, password)
  bb = DoBamBam.new(url, login, password)
  p bb.users
  exit


  tasks = bb.tasks
  puts tasks['result'].count
end

def convert_to_jira(base_uri, login, password, limit=nil, map_users={})
  result = {}
  bb = DoBamBam.new(base_uri, login, password)

  result['users'] = []
  users = bb.users
  if users
    users.each do |user_id, u|
      next if map_users.has_key?(user_id)

      result['users'].append({
        "name" => u['shortName'],
        "groups" => [ "jira-users" ],
        "active" => true,
        "email" => u['email'],
        "fullname" => make_full_name(u['firstName'], u['lastName'])
      })
    end
  end

  result['projects'] = []
  projects = bb.projects
 
  if projects
    projects.each do |p|
      key = p['name'].gsub(/[^a-zA-Z0-9]/, '').upcase[0,10]
      project = {
        "name" => p['name'],
        "key" => key,
        "description" => p['description'],
        "versions" => [],
        "components" => [], # No components in DoBamBam
        "issues" => []
      }

      #milestones = Set.new

=begin # Do not export milestones as versions
      $stderr.puts "Fetching milestones for project #{p['name']}"
      milestones = bb.milestones(p['context']['projectId'])
      milestones.each do |m|
        project['versions'].append({
          'name' => m['name'],
          'released' => m['completed'],
          'releaseDate' => convert_date_to_jira_time(m['completedDate']),
          'startDate' => convert_date_to_jira_time(m['startDate']),
          'dueDate' => convert_date_to_jira_time(m['dueDate']),
        })
      end
=end
      $stderr.puts "Fetching tasks for project #{p['name']}"
      issue_count = 0
      bb.tasks(p['context']['projectId']) do |t|
        break if limit and issue_count >= limit

        followers = bb.fetch_ticket_followers(t['id'], p['context']['projectId'])

        add_nonexistent_user(t['opener'], users, result['users'], map_users)
        add_nonexistent_user(t['assignment'].first, users, result['users'], map_users) if t['assignment'].count>0

        issue = {
                'key' => "#{key}-#{t['relativeId']}",
                'externalId' => t['relativeId'],
                'priority' => t['priority']['name'],
                'description' => convert_markup(t['desc'], key),
                'status' => t['status']['name'],
                'reporter' => get_short_name(t['opener'], map_users),
                'labels' => t['ticketLabels'].map {|l| l['name'].gsub(' ', '_')},
                'watchers' => followers.map {|f| get_short_name(f, map_users)},
                'issueType' => select_issue_type_by_labels(t['ticketLabels']), # There are no ticket types in DoBamBam
                'resolution' => is_resolved?(t) ? 'Resolved' : '',
                'created' => convert_timestamp_to_jira_time(t['created']),
                'updated' => convert_timestamp_to_jira_time(t['updated']),
                'duedate' => t['dueDate'], # Same format here!
                'originalEstimate' => calc_original_estimation(t),
                'estimate' => t['estimation'] ? "PT#{t['estimation'].to_i / 60}H" : nil,
                'affectedVersions' => [], # DoBamBam doesn't provide versions
                "summary" => "#{t['title']}",
                'assignee' => t['assignment'].count>0 ? get_short_name(t['assignment'].first, map_users) : nil,
                'fixedVersions' => [], # DoBamBam doesn't provide versions
                'components' => [], # DoBamBam doesn't provide components
                'history' => [],
                'customFieldValues' => [],
                #'worklogs' => [], #No worklogs in DoBamBam
                'attachments' => [],
                'comments' => [],
        }
        if t['milestone'] and t['milestone']['name']
          issue['customFieldValues'].append({
                "fieldName" => "Milestone",
                #"fieldType" => "com.pyxis.greenhopper.jira:gh-epic-link",
                "fieldType" => 'com.atlassian.jira.plugin.system.customfieldtypes:textfield',
                "value" => t['milestone']['name']
          })
          #milestones << t['milestone']['name']
        end

        attachments = []

        t['updates'].each do |u|
          add_nonexistent_user(u['owner'], users, result['users'], map_users)
          up = {
            'author' => get_short_name(u['owner'], map_users),
            'created' => convert_timestamp_to_jira_time(u['created']),
            'items' => []
          }
          u.keys.each do |k|
            if k == 'comment'
              issue['comments'].append({
                'body' => convert_markup(u[k], key),
                'author' => get_short_name(u['owner'], map_users),
                'created' => convert_timestamp_to_jira_time(u['created'])
              })
              next
            end

            next unless k.end_with?('Update')
            changed = k[0..-7]
            case changed
            when 'assignment'
              add_nonexistent_user(u[k]['old'].first, users, result['users'], map_users) if u[k]['old'].first
              add_nonexistent_user(u[k]['new'].first, users, result['users'], map_users) if u[k]['new'].first

              up['items'].append({
                                    "fieldType" => "jira",
                                    "field" => "assignee",
                                    "from" => u[k]['old'].first ? get_short_name(u[k]['old'].first, map_users) : nil,
                                    #"fromString" => "Open",
                                    "to" => u[k]['new'].first ? get_short_name(u[k]['new'].first, map_users) : nil,
                                    #"toString" => "Resolved"
                                })
            when 'status' 
              up['items'].append({
                                    "fieldType" => "jira",
                                    "field" => "status",
                                    "from" => u[k]['old']['name'],
                                    #"fromString" => "Open",
                                    "to" => u[k]['new']['name'],
                                    #"toString" => "Resolved"
                                })
            when 'dueDate' 
              up['items'].append({
                                    "fieldType" => "jira",
                                    "field" => 'duedate',
                                    "from" => convert_timestamp_to_jira_date(u[k]['old']),
                                    "fromString" => convert_timestamp_to_jira_time(u[k]['old']),
                                    "to" => convert_timestamp_to_jira_date(u[k]['new']),
                                    "toString" => convert_timestamp_to_jira_time(u[k]['new'])
                                })
            when 'priority'
              up['items'].append({
                                    "fieldType" => "jira",
                                    "field" => 'priority',
                                    "from" => u[k]['old'].capitalize,
                                    #"fromString" => "Open",
                                    "to" => u[k]['new'].capitalize,
                                    #"toString" => "Resolved"
                                })
            when 'milestone'
              up['items'].append({
                                    "field" => "Milestone",
                                    "fieldType" => "com.atlassian.jira.plugin.system.customfieldtypes:textfield",
#                                    "fieldType" => "com.pyxis.greenhopper.jira:gh-epic-link",
                                    "from" => u[k]['old'] ? u[k]['old']['name'] : nil,
                                    #"fromString" => "Open",
                                    "to" => u[k]['new'] ? u[k]['new']['name'] : nil,
                                    #"toString" => "Resolved"
                                })
              #milestones << u[k]['new']['name'] if u[k]['new']
            when 'estimation' 
              up['items'].append({
                                    "fieldType" => "jira",
                                    "field" => "timeestimate",
                                    "from" => u[k]['old'] ? u[k]['old'].to_i / 60 : nil,
                                    #"fromString" => "Open",
                                    "to" => u[k]['new'] ? u[k]['new'].to_i / 60 : nil,
                                    #"toString" => "Resolved"
                                })
            when 'attachments'
              raise "Unknown attachmentsUpdate type '#{u[k][type]}' in (u[k])" unless u[k]['type'] == 'ADDED'
              u[k]['attachments'].each do |a|
                raise "Unknown addType for attachment '#{a['addType']}' in (#{a})" unless a['addType'] == 'BY_UPDATE_TICKET'
                att_url = bb.fetch_attachment_url(a['hash'])
                up['items'].append({
                                    "fieldType" => "jira",
                                    "field" => "Attachment",
                                    'from' => nil,
                                    "to" => a['name'],
                                  })
                                  attachments.append({
                                    'name' => a['name'],
                                    'attacher' => get_short_name(u['owner'], map_users),
                                    'created' => convert_timestamp_to_jira_time(u['created']),
                                    'uri' => att_url,
                                  })
              end
            when 'labels' 
              up['items'].append({
                                    "fieldType" => "jira",
                                    "field" => "labels",
                                    "from" => (u[k]['old'].map {|l| l['name'].gsub(' ', '_')}).join(' '),
                                    "to" => (u[k]['new'].map {|l| l['name'].gsub(' ', '_')}).join(' '),
                                })
            else
              raise "Unknown update: #{k} (#{u[k]})"
            end
          end
          issue['history'].append(up) if up['items'].any?
        end

=begin # Were allready processed as updates
        t['attachmentsUpdate'].each do |a|
          raise "Unknown addType #{a['addType']} in (#{a})" if a['addType'] != 'BY_UPDATE_TICKET'
          add_nonexistent_user(a['creator'], users, result['users'], map_users)
          issue['attachments'].append({
            'name' => a['name'],
            'attacher' => get_short_name(a['creator'], map_users),
            'created' => convert_timestamp_to_jira_time(a['created']),
            'uri' => bb.fetch_attachment_url(a['hash']),
            'description' => a['title']
          })
        end
=end
        t['attachmentsAdd'].each do |a|
          raise "Unknown addType #{a['addType']} in (#{a})" if a['addType'] != 'BY_ADD_TICKET'
          add_nonexistent_user(a['creator'], users, result['users'], map_users)
          issue['attachments'].append({
            'name' => a['name'],
            'attacher' => get_short_name(a['creator'], map_users),
            'created' => convert_timestamp_to_jira_time(a['created']),
            'uri' => bb.fetch_attachment_url(a['hash']),
            'description' => a['title']
          })
        end
        issue['attachments'] += attachments

        project['issues'].append(issue)
        issue_count += 1
      end

=begin
      milestones.each do |m|
        project['issues'].append({
          'issueType' => 'Epic',
          "summary" => m,
        })
      end
=end

      result['projects'].append project
    end
  end

  result
end

def get_short_name(udata, map_users)
  id = udata['id'].to_i
  map_users.has_key?(id) ? map_users[id] : udata['shortName']
end

def convert_markup(text, project_key)
  return nil if text.nil?
  found_links = false
  text.gsub! /\<bl cid="(?<id>\d+)" type="(?<type>[^"]+)" pid="\d+" hash="[\da-z]+" label="[^"]*">#\k<id> - .*?\<\/bl>/m do |match|
    raise "Unknown link type: #{$2}" if $2 != 'TICKET'
    found_links = true
    "```TICKETLINK#{$1}TICKETLINK```"
  end
  parser = HTMLToConfluenceParser.new
  parser.feed(text)
  text = parser.to_wiki_markup
  text.gsub!(/%{[^}]+}(.+?)%/m, '\1') # remove buggy percent-tags
  text.gsub!(/```TICKETLINK(\d+)TICKETLINK```/m, "##{project_key}-\\1") if found_links
  text
end

def make_full_name(first_name, last_name)
  fullname = first_name
  fullname += ' ' if not (fullname.nil? || fullname.empty?) and not (last_name.nil? || last_name.empty?)
  fullname += last_name if not (last_name.nil? || last_name.empty?)
  fullname
end

def add_nonexistent_user(udata, users, result_users, map_users)
  unless users.has_key?(udata['id']) or map_users.has_key?(udata['id'].to_i)
    users[udata['id']] = udata
    result_users.append({
      "name" => udata['shortName'],
      "groups" => [ "jira-users" ],
      "active" => false,
      "email" => udata['email'],
      "fullname" => make_full_name(udata['firstName'], udata['lastName'])
    })
  end
end

def select_issue_type_by_labels(labels)
  return 'Bug' if labels.any?{ |t| t['name'].casecmp('bug')==0 }
  return 'Task'
end

def calc_original_estimation(ticket)
  est = nil
  ticket['updates'].each do |u|
    next unless u['estimationUpdate']
    if u['estimationUpdate']['old'] and not u['estimationUpdate']
      est = u['estimationUpdate']['new'].to_i / 60
      break
    end
  end
  est = "PT#{est}H" if est
  est
end

def is_resolved?(ticket)
  return true if ticket['status']['name'] == 'Resolved'
  return false unless ticket['status']['name'] == 'Closed'

  ticket['updates'].reverse_each do |u|
    next unless u['statusUpdate']
    return u['statusUpdate']['old']['name'] == 'Resolved'
  end
end

def convert_date_to_jira_time(d)
  Date.strptime(d, '%Y-%m-%d').strftime('%Y-%m-%dT%H:%M:%S.%L%z') if d
end

def convert_timestamp_to_jira_time(t)
  Time.at(t.to_i).strftime('%Y-%m-%dT%H:%M:%S.%L%z') if t
end

def convert_timestamp_to_jira_date(t)
  Time.at(t.to_i).strftime('%Y-%m-%d') if t
end

sl = Slop.new(help: true, strict: true) do
  on 'b', 'base_uri=', 'DoBamBam base URI, i.e https://yourcompany.dobambam.com/', required: true
  on 'u', 'user=', 'DoBamBam user', required: true
  on 'p', 'password=', 'DoBamBam user password', required: true
  on 'l', 'limit=', 'Limit per-project issues count', optional: true
  on 'm', 'map_users=', 'Map BamBam users to existing Jira users (format: bambam_user_id:jira_login,...)', as: Array, optional: true 
end

begin
  sl.parse
  opts = sl.to_hash

  map_users = {}
  opts[:map_users].each do |mu|
    bambam_id, jira_login = mu.split(':')
    if bambam_id.empty? or jira_login.empty? or (bambam_id = bambam_id.to_i) <= 0
      raise "Wrong users mapping format"
    end
    map_users[bambam_id] = jira_login
  end if opts[:map_users]
rescue
  $stderr.puts sl.help
  exit 1
end

result = convert_to_jira(opts[:base_uri], opts[:user], opts[:password], opts[:limit] ? opts[:limit].to_i : nil, map_users)
puts JSON.pretty_generate(result)
