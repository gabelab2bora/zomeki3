# Use this file to easily define all of your cron jobs.
#
# It's helpful, but not entirely necessary to understand cron before proceeding.
# http://en.wikipedia.org/wiki/Cron

# Example:
#
# set :output, "/path/to/my/cron_log.log"
#
# every 2.hours do
#   command "/usr/bin/some_great_command"
#   runner "MyModel.some_method"
#   rake "some:great:rake:task"
# end
#
# every 4.days do
#   runner "AnotherModel.prune_old_records"
# end

# Learn more: http://github.com/javan/whenever

# set :environment, 'development'

set :output, nil

env :PATH, ENV['PATH']

# 音声ファイルを静的ファイルとして書き出します。
every '6-51/15 * * * *' do
  rake 'zomeki:cms:talks:exec'
end

# アンケートの回答データを取り込みます。
every '9-54/15 * * * *' do
  rake 'zomeki:survey:answers:pull'
end

# 広告バナーのクリック数を取り込みます。
every '12-57/15 * * * *' do
  rake 'zomeki:ad_banner:clicks:pull'
end

# サイトの設定を定期的に更新します。
every '25,55 * * * *' do
  rake 'zomeki:cms:sites:update_server_configs'
end

# delayed_jobプロセスを監視します。
every '26,56 * * * *' do
  rake 'delayed_job:monitor'
end

# Feedコンテンツで設定したRSS・Atomフィードを取り込みます。
every :hour do
  rake 'zomeki:feed:feeds:read'
end

# リンクチェックを実行します。
every :hour do
  rake 'zomeki:cms:link_checks:exec'
end

# 不要データを削除します。
every :day, at: '0:00 am' do
  rake 'zomeki:sys:cleanup'
end

# 今日のイベントページを静的ファイルとして書き出します。
every :day, at: '0:10 am' do
  rake 'zomeki:gp_calendar:publish_todays_events'
end

# 今月の業務カレンダーを静的ファイルとして書き出します。
every :month, at: '0:15 am' do
  rake 'zomeki:biz_calendar:publish_this_month'
end

# アクセスランキングデータを取り込みます。
every :day, at: '0:30 am' do
  rake 'zomeki:rank:ranks:exec'
end

# 静的ファイルを書き出します。
every :day, at: '1:00 am' do
  rake 'zomeki:cms:nodes:publish'
end

# 静的ファイルを転送します。
every :day, at: '5:00 am' do
  rake 'zomeki:cms:file_transfers:exec'
end
