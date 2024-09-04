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

      home_team = m.parent.children[1].children[7].children[1].children.first.text.strip.split('@').last.gsub(/\s+/, "").gsub(/[[:space:]]/,'')
      away_team = m.parent.children[1].children[7].children[1].children.first.text.strip.split('@').first.gsub(/\s+/, "").gsub(/[[:space:]]/,'')

      match = savant_lineups.select{|x| x[:home][:name].split(' ').join.include?(home_team)}.first
      home_pitcher_id = match[:home][:name].split(' ').join.include?(home_team) ? match[:home][:pitcher_id] : match[:away][:pitcher_id]
      away_pitcher_id = match[:home][:name].split(' ').join.include?(away_team) ? match[:home][:pitcher_id] : match[:away][:pitcher_id]

      {
        id: 'koko',
        home: {
          name: m.parent.children[1].children[7].children[1].children.first.text.strip.split('@').last.gsub(/\s+/, ""),
          pitcher_id: home_pitcher_id,
          pitcher_name: m.children[3].children[1].children[3]&.text,
          player_ids: home_players
        },
        away: {
          name: m.parent.children[1].children[7].children[1].children.first.text.strip.split('@').first.gsub(/\s+/, ""),
          pitcher_id: away_pitcher_id,
          pitcher_name: m.children[1].children[1].children[3]&.text,
          player_ids: away_players
        }
      }
    end
  end

  def stats
    res = lineups.each_with_object([]) do |l, arr|
      @cached_stats = {}

      puts "Fetching stats for #{l[:home][:name]} - #{l[:away][:name]}..."
      #home_odd = todays_odds.find{|x| x[:home] == l[:home][:name] || x[:away] == l[:away][:name]}&.dig(:home_odd)
      #away_odd = todays_odds.find{|x| x[:home] == l[:home][:name] || x[:away] == l[:away][:name]}&.dig(:away_odd)

      unless l[:home][:pitcher_id] && l[:away][:pitcher_id]
        puts 'Pitcher not found, match will be skipped'
        next
      else
        puts "#{l[:home][:pitcher_name]} vs #{l[:away][:pitcher_name]}"
      end

      #home_stats = player_stats(l[:home][:pitcher_id])
      home_pitcher_era =  pitcher_stats(l[:home][:pitcher_id])[pitcher_stats(l[:home][:pitcher_id]).index{|x| x.text == 'xERA'} + 1].text.to_f
      #python_script = './statcast.py'
      #home_pitcher_era = `python3 #{python_script} #{l[:home][:pitcher_id]} 2024`.split("\n").last.to_f


      #away_stats = player_stats(l[:away][:pitcher_id])
      away_pitcher_era = pitcher_stats(l[:away][:pitcher_id])[pitcher_stats(l[:away][:pitcher_id]).index{|x| x.text == 'xERA'} + 1].text.to_f
      #away_pitcher_era = `python3 #{python_script} #{l[:away][:pitcher_id]} 2024`.split("\n").last.to_f

      puts "Warning!!! #{l[:home][:pitcher_name]} has no ERA" if home_pitcher_era&.zero?

      puts "Warning!!! #{l[:away][:pitcher_name]} has no ERA" if away_pitcher_era&.zero?

      arr <<
        {
          home_team: l[:home][:name],
          away_team: l[:away][:name],
          home_pitcher: {
            era: home_pitcher_era,
            name: l[:home][:pitcher_name],
            era_warning: home_pitcher_era&.zero?
            #avg_ko: player_stats(l[:home][:pitcher_id])['Data'].first['PitchingStrikeouts'] / player_stats(l[:home][:pitcher_id])['Data'].first['Games'].to_f
          },
          away_pitcher: {
            era: away_pitcher_era,
            name: l[:away][:pitcher_name],
            era_warning: away_pitcher_era&.zero?
            #avg_ko: player_stats(l[:away][:pitcher_id])['Data'].first['PitchingStrikeouts'] / player_stats(l[:away][:pitcher_id])['Data'].first['Games'].to_f
          },
          home_avg_rbi: l[:home][:player_ids].map { |rb| player_stats(rb)&.children.to_a[10]&.text.to_f / player_stats(rb)&.children.to_a[3]&.text.to_f },
          away_avg_rbi: l[:away][:player_ids].map { |rb| player_stats(rb)&.children.to_a[10]&.text.to_f / player_stats(rb)&.children.to_a[3]&.text.to_f },
          home_odd: nil,
          away_odd: nil
        }
    end
    selenium_driver.close
    res
  end

  def player_stats(player_id)
    @cached_stats[player_id] || begin
      d = HTTParty.get("https://fantasydata.com/mlb/a-b-fantasy/#{player_id}", timeout: 120)

      @cached_stats[player_id] =
        #HTTParty.post("https://fantasydata.com/MLB_Player/PlayerSeasonStats?sort=&page=1&pageSize=50&group=&filter=&playerid=#{player_id}&season=2024&scope=1", timeout: 120)
        Nokogiri::HTML(d.body).xpath("//*[@class='d-inline-block']")[1].
        children[1].
        children[7].
        children.select{|x| x&.children&.first&.children&.first&.text == '2024'}.first
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
      elements = selenium_driver.find_element(id: "percentile-slider-viz").attribute("innerHTML")
      @cached_stats[player_id] = Nokogiri::XML(elements).xpath("//text")
      @cached_stats[player_id]
    end
  end

  def games_url
    "https://fantasydata.com/mlb/daily-lineups?date=#{Date.today.to_s}"
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
    "https://baseballsavant.mlb.com/schedule?date=#{Date.today.to_s}"
  end
end
