require_relative './base_handler.rb'
class FantasyDataHandler < BaseHandler
  def data
    d = HTTParty.get(games_url,
      headers: { 'Content-Type' => 'application/json' })
      Nokogiri::HTML(d.body).xpath("//*[@class='lineup']")
  end

  def lineups
    data.map do |m|
      home_players = m.children[3].children.map do |c|
        next if c.children.empty?
        c.children[3].nil? ? nil : c.children[3].attributes['href'].value.split('/').last
      end.compact
      home_players.delete_at(0)

      away_players = m.children[1].children.map do |c|
        next if c.children.empty?
        c.children[3].nil? ? nil : c.children[3].attributes['href'].value.split('/').last
      end.compact
      away_players.delete_at(0)

      team_text = m.parent.at_css('.info div').xpath('text()').first.text.strip
      home_team = team_text.split('@').last.gsub(/[[:space:]]/, '')
      away_team = team_text.split('@').first.gsub(/[[:space:]]/, '')

      match = savant_lineups.select{|x| x[:home][:name].split(' ').join.include?(home_team)}.first
      home_pitcher_id = match[:home][:name].split(' ').join.include?(home_team) ? match[:home][:pitcher_id] : match[:away][:pitcher_id]
      away_pitcher_id = match[:home][:name].split(' ').join.include?(away_team) ? match[:home][:pitcher_id] : match[:away][:pitcher_id]

      {
        id: 'koko',
        home: {
          name: home_team,
          pitcher_id: home_pitcher_id,
          pitcher_name: match[:home][:pitcher_name],
          player_ids: home_players
        },
        away: {
          name: away_team,
          pitcher_id: away_pitcher_id,
          pitcher_name: match[:away][:pitcher_name],
          player_ids: away_players
        }
      }
    end
  end

  def stats
    res = lineups.each_with_object([]) do |l, arr|
      @cached_stats = {}
      puts "Fetching stats for #{l[:home][:name]} - #{l[:away][:name]}..."

      unless l[:home][:pitcher_id] && l[:away][:pitcher_id]
        puts 'Pitcher not found, match will be skipped'
        next
      else
        puts "#{l[:home][:pitcher_name]} vs #{l[:away][:pitcher_name]}"
      end

      #home_stats = player_stats(l[:home][:pitcher_id])
      home_nodes = pitcher_stats(l[:home][:pitcher_id])
      away_nodes = pitcher_stats(l[:away][:pitcher_id])

      home_pitcher_era       = extract_pitcher_stat(home_nodes, 'xERA')
      away_pitcher_era       = extract_pitcher_stat(away_nodes, 'xERA')
      home_pitcher_k_rate    = extract_pitcher_stat(home_nodes, 'K %') / 100.0
      away_pitcher_k_rate    = extract_pitcher_stat(away_nodes, 'K %') / 100.0
      home_pitcher_bb_rate   = extract_pitcher_stat(home_nodes, 'BB %') / 100.0
      away_pitcher_bb_rate   = extract_pitcher_stat(away_nodes, 'BB %') / 100.0
      home_pitcher_hard_hit  = extract_pitcher_stat(home_nodes, 'Hard Hit%') / 100.0
      away_pitcher_hard_hit  = extract_pitcher_stat(away_nodes, 'Hard Hit%') / 100.0

      puts "Warning!!! #{l[:home][:pitcher_name]} has no ERA" if home_pitcher_era&.zero?
      puts "Warning!!! #{l[:away][:pitcher_name]} has no ERA" if away_pitcher_era&.zero?

      arr <<
        {
          home_team: l[:home][:name],
          away_team: l[:away][:name],
          home_pitcher: {
            era:          home_pitcher_era,
            k_rate:       home_pitcher_k_rate,
            bb_rate:      home_pitcher_bb_rate,
            hard_hit_pct: home_pitcher_hard_hit,
            name:         l[:home][:pitcher_name],
            era_warning:  home_pitcher_era&.zero?
          },
          away_pitcher: {
            era:          away_pitcher_era,
            k_rate:       away_pitcher_k_rate,
            bb_rate:      away_pitcher_bb_rate,
            hard_hit_pct: away_pitcher_hard_hit,
            name:         l[:away][:pitcher_name],
            era_warning:  away_pitcher_era&.zero?
          },
          home_avg_rbi: l[:home][:player_ids].map { |rb| s = player_stats(rb); s&.children.to_a[11]&.text.to_f.then { |v| g = s&.children.to_a[3]&.text.to_f; g&.positive? ? v / g : nil } }.compact.select { |x| x.finite? && x > 0 },
          away_avg_rbi: l[:away][:player_ids].map { |rb| s = player_stats(rb); s&.children.to_a[11]&.text.to_f.then { |v| g = s&.children.to_a[3]&.text.to_f; g&.positive? ? v / g : nil } }.compact.select { |x| x.finite? && x > 0 }
        }
    end
    selenium_driver.quit
    res
  end

  def player_stats(player_id)
    @cached_stats[player_id] || begin
      d = HTTParty.get("https://fantasydata.com/mlb/a-b-fantasy/#{player_id}", timeout: 120)
      @cached_stats[player_id] =
        #HTTParty.post("https://fantasydata.com/MLB_Player/PlayerSeasonStats?sort=&page=1&pageSize=50&group=&filter=&playerid=#{player_id}&season=2024&scope=1", timeout: 120)
        Nokogiri::HTML(d.body).xpath("//*[@class='d-inline-block']")[1]
          &.children&.[](1)
          &.children&.[](7)
          &.children&.select{|x| x&.children&.first&.children&.first&.text == PROPOSAL_DATE.year.to_s}
          &.first
        @cached_stats[player_id]
    end
  end

  def selenium_driver
    @selenium_driver ||= begin
      options = Selenium::WebDriver::Options.chrome
      options.args << '--disable-search-engine-choice-screen'
      options.args << 'headless'
      driver = Selenium::WebDriver.for(:chrome, options: options)
    end
  end

  def pitcher_stats(player_id)
    @cached_stats[player_id] || begin
      selenium_driver.navigate.to player_stat_url(player_id)
      wait = Selenium::WebDriver::Wait.new(timeout: 15)
      wait.until { selenium_driver.find_element(id: "percentile-slider-viz").attribute("innerHTML").include?("xERA") }
      elements = selenium_driver.find_element(id: "percentile-slider-viz").attribute("innerHTML")
      @cached_stats[player_id] = Nokogiri::XML(elements).xpath("//text")
    rescue
      @cached_stats[player_id] = []
    ensure
      #selenium_driver.quit
      return @cached_stats[player_id]
    end
  end

  def games_url
    "https://fantasydata.com/mlb/daily-lineups?date=#{PROPOSAL_DATE.to_s}"
  end

  def player_stat_url(player_id)
    "https://baseballsavant.mlb.com/savant-player/#{player_id}?stats=statcast-r-pitching-mlb"
  end

  def savant_lineups
    @savant_lineups ||= begin
      data_json = HTTParty.get(savant_games_url, headers: { 'Content-Type' => 'application/json' })
      data_json.dig('schedule','dates')&.first['games'].map do |m|
        offense_team_id = data_json.dig('schedule','dates')&.first['games'].first.dig('linescore','offense','team','id')
        home_offense_mapping = offense_team_id == m.dig('teams', 'home', 'team', 'id') ? 'offense' : 'defense'
        away_offense_mapping = offense_team_id == m.dig('teams', 'away', 'team', 'id') ? 'offense' : 'defense'

        {
          id: m['gamePk'],
          home: {
            name: m.dig('teams', 'home', 'team', 'name'),
            pitcher_id: m.dig('teams', 'home', 'probablePitcher', 'id'),
            pitcher_name: m.dig('teams', 'home', 'probablePitcher', 'fullName'),
            player_ids: m.dig('linescore', home_offense_mapping)&.reject{|k, _| ['pitcher', 'batter', 'onDeck', 'inHole', 'team', 'battingOrder'].include?(k) }&.map{|_,v| v['id']},
          },
          away: {
            name: m.dig('teams', 'away', 'team', 'name'),
            pitcher_id: m.dig('teams', 'away', 'probablePitcher', 'id'),
            pitcher_name: m.dig('teams', 'away', 'probablePitcher', 'fullName'),
            player_ids: m.dig('linescore', away_offense_mapping)&.reject{|k, _| ['pitcher', 'batter', 'onDeck', 'inHole', 'team', 'battingOrder'].include?(k) }&.map{|_,v| v['id']},
          }
        }
      end
    end
  end

  def savant_games_url
    "https://baseballsavant.mlb.com/schedule?date=#{PROPOSAL_DATE.to_s}"
  end

end
