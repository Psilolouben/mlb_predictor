require_relative './base_handler.rb'
class FantasyDataHandler < BaseHandler
  def data
    d = HTTParty.get(GAMES_URL,
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

      {
        id: 'koko',
        home: {
          name: m.parent.children[1].children[7].children[1].children.first.text.strip.split('@').last.gsub(/\s+/, ""),
          pitcher_id: m.children[3].children[1].children[3].nil? ? nil : m.children[3].children[1].children[3].attributes['href'].value.split('/').last,
          pitcher_name: m.children[3].children[1].children[3]&.text,
          player_ids: home_players
        },
        away: {
          name: m.parent.children[1].children[7].children[1].children.first.text.strip.split('@').first.gsub(/\s+/, ""),
          pitcher_id: m.children[1].children[1].children[3].nil? ? nil : m.children[1].children[1].children[3].attributes['href'].value.split('/').last,
          pitcher_name: m.children[1].children[1].children[3]&.text,
          player_ids: away_players
        }
      }
    end
  end

  def stats
    lineups.take(2).each_with_object([]) do |l, arr|
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

      home_stats = player_stats(l[:home][:pitcher_id])
      home_pitcher_era =  home_stats.nil? ? 0 : home_stats.children[9].text.to_f

      away_stats = player_stats(l[:away][:pitcher_id])

      away_pitcher_era = away_stats.nil? ? 0 : away_stats.children[9].text.to_f

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
end
