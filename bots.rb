require 'twitter_ebooks'
require_relative 'boodoo'
require 'dotenv'

include Ebooks::Boodoo

# Read defaults and lay env vars on top:
SETTINGS = Dotenv.load('defaults.env').merge(ENV)


# Information about a particular Twitter user we know
class UserInfo
  attr_reader :username

  # @return [Integer] how many times we can pester this user unprompted
  attr_accessor :pesters_left

  # @param username [String]
  def initialize(username)
    @username = username
    @pesters_left = parse_num(SETTINGS['PESTER_COUNT']) || 1
  end
end

class BoodooBot
  attr_accessor :original, :model, :model_path, :auth_name, :archive_path, :archive
  attr_accessor :followers, :following
  def configure
    # create attr_accessors for all SETTINGS fields
    SETTINGS.keys.map(&:to_s).map(&:downcase).each(&Ebooks::Bot.method(:attr_accessor))

    # String fields taken as-is:
    @consumer_key =       SETTINGS['CONSUMER_KEY']
    @consumer_secret =    SETTINGS['CONSUMER_SECRET']
    @access_token =       SETTINGS['ACCESS_TOKEN']
    @access_token_secret =SETTINGS['ACCESS_TOKEN_SECRET']
    @tweet_interval =     SETTINGS['TWEET_INTERVAL']
    @tweet_on_hour =      to_boolean(SETTINGS['TWEET_ON_HOUR'])
    @update_follows_interval = SETTINGS['UPDATE_FOLLOWS_INTERVAL']
    @refresh_model_interval = SETTINGS['REFRESH_MODEL_INTERVAL']

    # String fields forced to downcase:
    @bot_name =           SETTINGS['BOT_NAME']
    @original =           SETTINGS['SOURCE_USERNAME']

    # Array fields are CSV or SSV
    @blacklist =        parse_array(SETTINGS['BLACKLIST'])
    @banned_terms =     parse_array(SETTINGS['BANNED_TERMS'])
    $banned_terms =     @banned_terms
    @special_terms  =   parse_array(SETTINGS['SPECIAL_TERMS'])

    # Fields parsed as Fixnum, Float, or Range:
    @default_delay =    parse_range(SETTINGS['DEFAULT_DELAY'])
    @dm_delay =         parse_range(SETTINGS['DM_DELAY']) || parse_range(SETTINGS['DEFAULT_DELAY'])
    @mention_delay =    parse_range(SETTINGS['MENTION_DELAY']) || parse_range(SETTINGS['DEFAULT_DELAY'])
    @timeline_delay =   parse_range(SETTINGS['TIMELINE_DELAY']) || parse_range(SETTINGS['DEFAULT_DELAY'])
    @tweet_chance =     parse_num(SETTINGS['TWEET_CHANCE'])
    @timeout_sleep =    parse_num(SETTINGS['TIMEOUT_SLEEP'])

    # from upstream example
    @userinfo = {}

    # added for BooDoo variant
    @attempts = 0
    @followers = []
    @following = []
    @archive_path = "corpus/#{@original}.json"
    @model_path = "model/#{@original}.model"

    if can_run?
      get_archive!
      make_model!
    else
      missing_fields.each {|missing|
        log "Can't run without #{missing}"
      }
      log "Heroku will automatically try again immediately or in 10 minutes..."
      Kernel.exit(1)
    end
  end

  def top100; @top100 ||= model.keywords.take(100); end
  def top20;  @top20  ||= model.keywords.take(20); end

  # Overwrites Ebooks::Bot#delay, but do we gain anything doing so?
  def delay(d, &b)
    d ||= default_delay
    sleep (d || [0]).to_a.sample
    b.call
  end

  def on_startup
    log "I started up!"
    tweet(model.make_statement)

    scheduler.interval @tweet_interval do
      if rand < @tweet_chance
        if @tweet_on_hour
          tweet(model.make_statement)
        else
          # schedule tweet to happen at a random minute this hour
          this_many_min = rand(1..59).to_s + 'm'
          log "Scheduling tweet in #{this_many_min} min!"
          scheduler.in.this_many_min do
            tweet(model.make_statement)
          end
        end
      end
    end

    scheduler.interval @update_follows_interval do
      follow_parity
    end

    scheduler.interval @refresh_model_interval do
      log "Refreshing archive/model..."
      get_archive!
      make_model!
    end
  end

  def on_message(dm)
    from_owner = dm.sender.screen_name.downcase == @original.downcase
    log "[DM from owner? #{from_owner}]"
    if from_owner
      action = dm.text.split.first.downcase
      strip_re = Regexp.new("^#{action}\s*", "i")
      payload = dm.text.sub(strip_re, "")
      #TODO: Add blacklist/whitelist/reject(banned phrase)
      #TODO? Move this into a DMController class or equivalent?
      case action
      when "tweet"
        tweet model.make_response(payload, 140)
      when "follow", "unfollow", "block"
        payload = parse_array(payload.gsub("@", ''), / *[,; ]+ */) # Strip @s and make array
        send(action.to_sym, payload)
      when "mention"
        pre = payload + " "
        limit = 140 - pre.size
        message = "#{pre}#{model.make_statement(limit)}"
        tweet message
      when "cheating"
        tweet payload
      else
        log "Don't have behavior for action: #{action}"
        reply(dm, model.make_response(dm.text))
      end
    else
      #otherwise, just reply like a mention
      delay(dm_delay) do
        reply(dm, model.make_response(dm.text))
      end
    end
  end

  def on_mention(tweet)
    # Become more inclined to pester a user when they talk to us
    userinfo(tweet.user.screen_name).pesters_left += 1

    delay(mention_delay) do
      reply(tweet, model.make_response(meta(tweet).mentionless, meta(tweet).limit))
    end
  end

  def on_timeline(tweet)
    return if tweet.retweeted_status?
    return unless can_pester?(tweet.user.screen_name)

    tokens = Ebooks::NLP.tokenize(tweet.text)

    interesting = tokens.find { |t| top100.include?(t.downcase) }
    very_interesting = tokens.find_all { |t| top20.include?(t.downcase) }.length > 2

    delay(timeline_delay) do
      if very_interesting
        favorite(tweet) if rand < 0.5
        retweet(tweet) if rand < 0.01
        if rand < 0.01
          userinfo(tweet.user.screen_name).pesters_left -= 1
          reply(tweet, model.make_response(meta(tweet).mentionless, meta(tweet).limit))
        end
      elsif interesting
        favorite(tweet) if rand < 0.05
        reply(tweet, model.make_response(meta(tweet).mentionless, meta(tweet).limit)) if rand < 0.01
      end
    end
  end

  # Find information we've collected about a user
  # @param username [String]
  # @return [Ebooks::UserInfo]
  def userinfo(username)
    @userinfo[username] ||= UserInfo.new(username)
  end

  # Check if we're allowed to send unprompted tweets to a user
  # @param username [String]
  # @return [Boolean]
  def can_pester?(username)
    userinfo(username).pesters_left > 0
  end

  # Only follow our original user or people who are following our original user
  # @param user [Twitter::User]
  def can_follow?(username)
    @original.nil? || username == @original || twitter.friendship?(username, @original) || twitter.friendship?(username, @username)
  end

  def favorite(tweet)
    if can_follow?(tweet.user.screen_name)
      super(tweet)
    else
      log "Unfollowing @#{tweet.user.screen_name}"
      twitter.unfollow(tweet.user.screen_name)
    end
  end

  def on_follow(user)
    if can_follow?(user.screen_name)
      follow(user.screen_name)
    else
      log "Not following @#{user.screen_name}"
    end
  end

  # Prefilter for banned terms before tweeting
  def tweet(text, *args)
    text = obscure_curses(text)
    super(text, *args)
  end

  # Prefilter for banned terms before replying
  def reply(ev, text, opts={})
    text = obscure_curses(text)
    super(ev, text, opts)
  end
 
  # Helps us convert usage of "true" and "false" strings in .env files to booleans
  def to_boolean(str)
    str == 'true'
  end 

  private
  def load_model!
    return if @model

    @model_path ||= "model/#{original}.model"

    log "Loading model #{model_path}"
    @model = Ebooks::Model.load(model_path)
  end
end

BoodooBot.new(SETTINGS['BOT_NAME']) do |bot|
  # BoodooBot#configure does everything!
  bot
end
