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
  end

  def fetch_ticket(project_id, task_id, task_relative_id)
    login
    result = RestClient.get("#{@base_uri}ajax/fetch-ticket.html?ticketId=#{task_id}&projectId=#{project_id}&relativeId=#{task_relative_id}",
                               {cookies: {'SLS2_SESSIDv4' => @session_id}})
    JSON.parse(result)['ticket']
  end

  def fetch_ticket_followers(ticket_id, project_id)
    login
    result = RestClient.post("#{@base_uri}followers/list",
                            {type: 'TICKET', param: ticket_id, projectId: project_id},
                            {cookies: {'SLS2_SESSIDv4' => @session_id}})
    ids = JSON.parse(result)['result']
    user_info = users
    ids.map {|id| user_info[id]}
  end

  def fetch_attachment_url(h)
    @attachment_urls ||= {}
    return @attachment_urls[h] if @attachment_urls[h]

    login
    result = RestClient.get("#{@base_uri}file/download?fileId=#{h}",
                            {cookies: {'SLS2_SESSIDv4' => @session_id}}) do |response, request, result, &block|
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

def convert_to_jira(base_uri, login, password)
  result = {}
  bb = DoBamBam.new(base_uri, login, password)
  parser = HTMLToConfluenceParser.new

  result['users'] = []
  users = bb.users
  if users
    users.each do |u|
      result['users'].append({
        "name" => u['shortName'],
        "groups" => [ "jira-users" ],
        "active" => true,
        "email" => u['email'],
        "fullname" => u['firstName'] + ' ' + u['lastName']
      })
    end
  end

  result['projects'] = []
  projects = bb.projects
 
  if projects
    projects.each do |p|
      key = p['name'].gsub(/[^a-zA-Z0-9]/, '').upcase
      project = {
        "name" => p['name'],
        "key" => key,
        "description" => p['description'],
        "versions" => [],
        "components" => [], # No components in DoBamBam
        "issues" => []
      }

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
      bb.tasks(p['context']['projectId']) do |t|
        parser.feed(t['desc'])
        converted_description = parser.to_wiki_markup

        followers = bb.fetch_ticket_followers(t['id'], p['context']['projectId'])

        issue = {
                'key' => "#{key}-#{t['relativeId']}",
                'externalId' => t['relativeId'],
                'priority' => t['priority']['name'],
                'description' => converted_description,
                'status' => t['status']['name'],
                'reporter' => t['opener']['shortName'],
                'labels' => t['ticketLabels'].map {|l| l['name']},
                'watchers' => followers.map {|f| f['shortName']},
                'issueType' => select_issue_type_by_labels(t['ticketLabels']), # There are no ticket types in DoBamBam
                'resolution' => is_resolved?(t) ? 'Resolved' : '',
                'created' => convert_timestamp_to_jira_time(t['created']),
                'updated' => convert_timestamp_to_jira_time(t['updated']),
                'dueTime' => convert_timestamp_to_jira_time(t['dueDate']),
                'originalEstimation' => calc_original_estimation(t),
                'estimation' => t['estimation'] ? "PT#{t['estimation']}H" : nil,
                'affectedVersions' => [], # DoBamBam doesn't provide versions
                "summary" => "#{t['title']}",
                'assignee' => t['assignment'].count>0 ? t['assignment'].first['shortName'] : nil,
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
                "fieldName" => "Epic Link",
                "fieldType" => "com.pyxis.greenhopper.jira:gh-epic-link",
                "value" => t['milestone']['name']
          })
        end

        t['updates'].each do |u|
          up = {
            'author' => u['owner']['shortName'],
            'created' => convert_timestamp_to_jira_time(u['created']),
            'items' => []
          }
          u.keys.each do |k|
            if k == 'comment'
              parser.feed(u[k])
              converted_comment = parser.to_wiki_markup

              issue['comments'].append({
                'body' => converted_comment,
                'author' => u['owner']['shortName'],
                'created' => convert_timestamp_to_jira_time(u['created'])
              })
              next
            end

            next unless k.end_with?('Update')
            changed = k[0..-7]
            case changed
            when 'assignment'
              up['items'].append({
                                    "fieldType" => "jira",
                                    "field" => "assignee",
                                    "from" => u[k]['old'].first ? u[k]['old'].first['shortName'] : nil,
                                    #"fromString" => "Open",
                                    "to" => u[k]['new'].first ? u[k]['new'].first['shortName'] : nil,
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
                                    "field" => 'dueTime',
                                    "from" => u[k]['old'],
                                    #"fromString" => "Open",
                                    "to" => u[k]['new'],
                                    #"toString" => "Resolved"
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
                                    "field" => "Epic Link",
                                    "fieldType" => "com.pyxis.greenhopper.jira:gh-epic-link",
                                    "from" => u[k]['old'] ? u[k]['old']['name'] : nil,
                                    #"fromString" => "Open",
                                    "to" => u[k]['new'] ? u[k]['new']['name'] : nil,
                                    #"toString" => "Resolved"
                                })
            when 'estimation' 
              up['items'].append({
                                    "fieldType" => "jira",
                                    "field" => "estimation",
                                    "from" => u[k]['old'] ? "PT#{u[k]['old']}H" : nil,
                                    #"fromString" => "Open",
                                    "to" => u[k]['new'] ? "PT#{u[k]['new']}H" : nil,
                                    #"toString" => "Resolved"
                                })
            when 'attachments'
              raise "Unknown attachmentsUpdate type '#{u[k][type]}' in (u[k])" unless u[k]['type'] == 'ADDED'
              u[k]['attachments'].each do |a|
                raise "Unknown addType for attachment '#{a['addType']}' in (#{a})" unless a['addType'] == 'BY_UPDATE_TICKET'
                up['items'].append({
                                    "fieldType" => "jira",
                                    "field" => "Attachment",
                                    'from' => nil,
                                    "fromString" => '',
                                    "toString" => bb.fetch_attachment_url(a['hash']),
                                  })
              end
            when 'labels' 
              up['items'].append({
                                    "fieldType" => "jira",
                                    "field" => "labels",
                                    "from" => u[k]['old'].map {|l| l['name']},
                                    "to" => u[k]['new'].map {|l| l['name']},
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
          issue['attachments'].append({
            'name' => a['name'],
            'attacher' => a['creator']['shortName'],
            'created' => convert_timestamp_to_jira_time(a['created']),
            'uri' => bb.fetch_attachment_url(a['hash']),
            'description' => a['title']
          })
        end
=end
        t['attachmentsAdd'].each do |a|
          raise "Unknown addType #{a['addType']} in (#{a})" if a['addType'] != 'BY_ADD_TICKET'
          issue['attachments'].append({
            'name' => a['name'],
            'attacher' => a['creator']['shortName'],
            'created' => convert_timestamp_to_jira_time(a['created']),
            'uri' => bb.fetch_attachment_url(a['hash']),
            'description' => a['title']
          })
        end

        project['issues'].append(issue)

      end

      result['projects'].append project
    end
  end

  result
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
      est = u['estimationUpdate']['new']
      break
    end
  end
  est = "PT#{est}h" if est
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
  DateTime.strptime(t.to_s, '%s').strftime('%Y-%m-%dT%H:%M:%S.%L%z') if t
end

sl = Slop.new(help: true, strict: true) do
  on 'b', 'base_uri=', 'DoBamBam base URI, i.e https://yourcompany.dobambam.com/', required: true
  on 'u', 'user=', 'DoBamBam user', required: true
  on 'p', 'password=', 'DoBamBam user password', required: true
end

begin
  sl.parse
rescue
  $stderr.puts sl.help
  exit 1
end

opts = sl.to_hash
result = convert_to_jira(opts[:base_uri], opts[:user], opts[:password])
puts result
