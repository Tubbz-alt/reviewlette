require 'reviewlette/trello_connection'
require 'reviewlette/github_connection'
require 'reviewlette/vacations'
require 'yaml'

# Assume cards have following card title when estimated
# (8) This is the card name'
POINTS_REGEX = /\(([\d]+)\)/

class Reviewlette
  def initialize
    @trello  = TrelloConnection.new
    @members = YAML.load_file("#{File.dirname(__FILE__)}/../config/members.yml")
    @github  = YAML.load_file("#{File.dirname(__FILE__)}/../config/github.yml")
  end

  def run
    @github['repos'].each do |repo|
      puts "Checking repository #{repo}..."
      check_repo(repo, @github['token'])
    end
  end

  def check_repo(repo_name, token)
    repo = GithubConnection.new(repo_name, token)

    unless repo.repo_exists?
      puts "Repository #{repo_name} does not exist. Check your configuration"
      return
    end

    repo.pull_requests.each do |issue|
      issue_id    = issue[:number]
      issue_title = issue[:title]
      issue_flags = scan_flags(issue_title)

      puts "*** Checking GitHub pull request: #{issue_title}"
      matched = issue_title.match(/\d+[_'"]?$/)

      unless matched
        puts 'Pull request not assigned to a trello card'
        next
      end

      card_id = matched[0].to_i
      card    = @trello.find_card_by_id(card_id)

      unless card
        puts "No matching card found (id #{card_id})"
        next
      end

      puts "Found matching trello card: #{card.name}"

      assignees = issue[:assignees].map { |a| a[:login] }
      already_assigned_members = @members.select { |m| assignees.include? m['github_username'] }
      wanted_number = how_many_should_review(issue_flags)

      reviewers = if assignees.size > wanted_number
                    change_in_reviewers = true
                    already_assigned_members[0...wanted_number]
                  elsif assignees.size < wanted_number
                    change_in_reviewers = true
                    select_reviewers(card, wanted_number, already_assigned_members)
                  else
                    change_in_reviewers = false
                    already_assigned_members
                  end

      if reviewers.empty?
        puts "Could not find a reviewer for card: #{card.name}"
        next
      end

      if change_in_reviewers
        repo.add_assignees(issue_id, reviewers.map { |r| r['github_username'] } )
        repo.comment_reviewers(issue_id, reviewers, card)
        @trello.comment_reviewers(card, repo_name, issue_id, reviewers)
      end
      @trello.move_card_to_list(card, 'In review')
    end
  end

  def scan_flags(issue_title)
    flags = issue_title[/\A\[(.*)\]/, 1]
    if flags
      flags.split(',').map(&:strip)
    else
      []
    end
  end

  def select_reviewers(card, number = 1, already_assigned = [])
    reviewers = @members

    # remove people on vacation
    members_on_vacation = Vacations.members_on_vacation(reviewers)

    reviewers = reviewers.reject { |r| members_on_vacation.include? r['suse_username'] }

    # remove trello card owner
    reviewers = reviewers.reject { |r| card.members.map(&:username).include? r['trello_username'] }

    # remove already assigned reviewers
    reviewers = reviewers.reject { |r| already_assigned.include? r }

    reviewers.sample(number - already_assigned.size) + already_assigned
  end

  def how_many_should_review(issue_flags)
    return 2 if issue_flags.include? '!'
    1
  end
end
