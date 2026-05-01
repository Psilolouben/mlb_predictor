class BaseHandler

  def upload_to_bucket
    storage = Google::Cloud::Storage.new(
      project_id: "mlb-bet-predictor",
      credentials: "mlb-bet-predictor-b83d3bb4dce7.json"
    )
    bucket = storage.bucket("gcf-v2-uploads-944915810467-us-central1")
    a = bucket.create_file("bet_proposals.csv", "bet_proposals.csv", cache_control: 'max-age=0')
    a.public_url
  end

  def export_to_csv(proposals)
    CSV.open("bet_proposals.csv", "w", col_sep: ';') do |csv|
      idx = 2
      csv << ['Team', 'Pitcher', 'Poss', 'Avg. Runs', 'O75', 'O85', 'O95', 'Both', 'MPH', 'MPA']

      proposals.each do |game|
        csv << [
          game[:home] > game[:away] ? "#{game[:home_team]}#{game[:home_pitcher][:era_warning] ? '*' : ''}" : "#{game[:away_team]}#{game[:away_pitcher][:era_warning] ? '*' : ''}",
          game[:home] > game[:away] ? game[:home_pitcher][:name] : game[:away_pitcher][:name],
          [game[:home], game[:away]].max.to_s.gsub('.',','),
          game[:avg_total_runs].to_s.gsub('.', ','),
          game[:o75].to_s.gsub('.', ','),
          game[:o85].to_s.gsub('.', ','),
          game[:o95].to_s.gsub('.', ','),
          game[:both_scored].to_s.gsub('.', ','),
          game[:most_possible_runs_home].to_s.gsub('.', ','),
          game[:most_possible_runs_away].to_s.gsub('.', ','),

          #"=(C#{idx}+D#{idx})/2"
        ]
        idx += 1
      end
    end;0
  end

  def extract_proposals(all_results, win_results)
    if win_results.empty?
      puts "Warning: no decisive simulations for #{all_results.first[:home_team]} vs #{all_results.first[:away_team]}, skipping"
      return nil
    end
    {
      home_team: all_results.first[:home_team],
      away_team: all_results.first[:away_team],
      home: (win_results.count { |x| x[:home] > x[:away] } / win_results.count.to_f) * 100,
      away: (win_results.count { |x| x[:home] < x[:away] } / win_results.count.to_f) * 100,
      avg_total_runs: all_results.sum { |x| x[:home] + x[:away] } / all_results.count.to_f,
      home_pitcher: all_results.first[:home_pitcher],
      away_pitcher: all_results.first[:away_pitcher],
      o75: (all_results.count { |x| (x[:home] + x[:away]) > 7.5 } / all_results.count.to_f) * 100,
      o85: (all_results.count { |x| (x[:home] + x[:away]) > 8.5 } / all_results.count.to_f) * 100,
      o95: (all_results.count { |x| (x[:home] + x[:away]) > 9.5 } / all_results.count.to_f) * 100,
      both_scored: (all_results.count { |x| x[:home] > 0 && x[:away] > 0 } / all_results.count.to_f) * 100,
      most_possible_runs_home: all_results.map { |x| x[:home].round }.tally.max_by { |_, v| v }&.first,
      most_possible_runs_away: all_results.map { |x| x[:away].round }.tally.max_by { |_, v| v }&.first
    }
  end
end
