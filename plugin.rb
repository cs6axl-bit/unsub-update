# frozen_string_literal: true

# name: unsub-update
# about: Postback when a user sets digest to "Never" via prefs/API or unsubscribe page. Also UI: ticking unsubscribe_all sets digest dropdown to never.
# version: 1.1.0
# authors: you

after_initialize do
  require "net/http"
  require "uri"
  require "json"

  module ::UnsubUpdateConfig
    ENABLED = true
    ENDPOINT_URL = "http://172.17.0.1:8081/unsub_update.php"
    MIN_MINUTES_SINCE_REGISTRATION = 2
    SHARED_SECRET = ""   # sent as form field "secret"
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 5

    # UI behavior: disable digest dropdown ONLY after user ticks the checkbox
    UI_DISABLE_DIGEST_DROPDOWN_WHEN_UNSUB_ALL = true
  end

  module ::UnsubUpdate
    def self.unsub_never?(user_option)
      return false if user_option.nil?
      user_option.email_digests == false || user_option.digest_after_minutes.to_i <= 0
    end

    def self.user_too_new?(user)
      min_age = ::UnsubUpdateConfig::MIN_MINUTES_SINCE_REGISTRATION.to_i.minutes
      user.created_at.present? && (Time.zone.now - user.created_at) < min_age
    end

    def self.no_mail_enabled?(user_option)
      return false if user_option.nil?
      return false unless user_option.respond_to?(:email_level)

      types =
        if user_option.class.respond_to?(:email_level_types)
          user_option.class.email_level_types
        else
          {}
        end

      never_val = types[:never]
      return false if never_val.nil?

      user_option.email_level.to_i == never_val.to_i
    end

    # IMPORTANT: your schema does NOT allow writing updated_at here.
    def self.force_digest_never!(user_option)
      return false if user_option.nil?

      needs_change =
        (user_option.email_digests != false) ||
        (user_option.digest_after_minutes.to_i > 0)

      return false unless needs_change

      user_option.update_columns(
        email_digests: false,
        digest_after_minutes: 0
      )
      true
    end
  end

  class ::Jobs::UnsubUpdatePostback < ::Jobs::Base
    def execute(args)
      return unless ::UnsubUpdateConfig::ENABLED

      user = User.find_by(id: args[:user_id].to_i)
      return if user.nil? || user.staged? || user.suspended?

      opt = user.user_option
      return unless ::UnsubUpdate.unsub_never?(opt)

      if ::UnsubUpdate.user_too_new?(user)
        Rails.logger.warn("[unsub-update] SKIP (too new) user_id=#{user.id}")
        return
      end

      payload = {
        "event" => "digest_set_to_never",
        "user_id" => user.id.to_s,
        "username" => user.username.to_s,
        "email" => user.email.to_s,
        "registered_at" => (user.created_at&.utc&.iso8601 || ""),
        "email_digests" => (opt&.email_digests.nil? ? "" : opt.email_digests ? "1" : "0"),
        "digest_after_minutes" => opt&.digest_after_minutes.to_i.to_s,
        "sent_at_utc" => Time.zone.now.utc.iso8601,
        "secret" => ::UnsubUpdateConfig::SHARED_SECRET
      }

      uri = URI(::UnsubUpdateConfig::ENDPOINT_URL)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = ::UnsubUpdateConfig::OPEN_TIMEOUT_SECONDS
      http.read_timeout = ::UnsubUpdateConfig::READ_TIMEOUT_SECONDS

      req = Net::HTTP::Post.new(uri.request_uri)
      req.set_form_data(payload)

      begin
        resp = http.request(req)
        code = resp.code.to_i
        if code >= 200 && code < 300
          Rails.logger.warn("[unsub-update] POST OK user_id=#{user.id} code=#{code}")
        else
          Rails.logger.warn("[unsub-update] POST FAILED user_id=#{user.id} code=#{code} body=#{resp.body.to_s[0, 500]}")
        end
      rescue => e
        Rails.logger.warn("[unsub-update] POST ERROR user_id=#{user.id} err=#{e.class}: #{e.message}")
      end
    end
  end

  # -----------------------------
  # 1) Trigger on prefs/API changes
  # -----------------------------
  UserOption.class_eval do
    after_commit :_unsub_update_after_commit, on: [:update]

    def _unsub_update_after_commit
      return unless ::UnsubUpdateConfig::ENABLED

      changed_digest =
        (respond_to?(:saved_change_to_email_digests?) && saved_change_to_email_digests?) ||
        (respond_to?(:saved_change_to_digest_after_minutes?) && saved_change_to_digest_after_minutes?) ||
        (previous_changes.key?("email_digests") || previous_changes.key?("digest_after_minutes"))

      changed_email_level =
        (respond_to?(:saved_change_to_email_level?) && saved_change_to_email_level?) ||
        previous_changes.key?("email_level")

      return unless (changed_digest || changed_email_level)

      u = self.user
      return if u.nil? || u.staged? || u.suspended?

      if ::UnsubUpdate.user_too_new?(u)
        Rails.logger.warn("[unsub-update] SKIP (too new) user_id=#{u.id}")
        return
      end

      if changed_email_level && ::UnsubUpdate.no_mail_enabled?(self)
        forced = ::UnsubUpdate.force_digest_never!(self)
        Rails.logger.warn("[unsub-update] NO-MAIL -> FORCE DIGEST NEVER user_id=#{u.id} forced=#{forced ? 1 : 0} source=user_option_update")
        ::Jobs.enqueue(:unsub_update_postback, user_id: u.id)
        return
      end

      return unless changed_digest
      return unless ::UnsubUpdate.unsub_never?(self)

      Rails.logger.warn("[unsub-update] ENQUEUE user_id=#{u.id} source=user_option_update")
      ::Jobs.enqueue(:unsub_update_postback, user_id: u.id)
    end
  end

  # -----------------------------
  # 2) Trigger on unsubscribe page submit (/email/unsubscribe/:key)
  # -----------------------------
  class ::EmailController
    module ::UnsubUpdateEmailUnsubscribeHook
      def unsubscribe
        super

        return unless ::UnsubUpdateConfig::ENABLED

        user = nil
        begin
          if defined?(::UnsubscribeKey)
            k = ::UnsubscribeKey.includes(:user).find_by(key: params[:key].to_s)
            user = k&.user
          end
        rescue => e
          Rails.logger.warn("[unsub-update] EMAIL-UNSUB resolve key error err=#{e.class}: #{e.message}")
        end

        return if user.nil? || user.staged? || user.suspended?

        if ::UnsubUpdate.user_too_new?(user)
          Rails.logger.warn("[unsub-update] EMAIL-UNSUB SKIP (too new) user_id=#{user.id}")
          return
        end

        opt = user.reload.user_option

        if ::UnsubUpdate.no_mail_enabled?(opt)
          forced = ::UnsubUpdate.force_digest_never!(opt)
          Rails.logger.warn("[unsub-update] EMAIL-UNSUB NO-MAIL -> FORCE DIGEST NEVER user_id=#{user.id} forced=#{forced ? 1 : 0}")
          ::Jobs.enqueue(:unsub_update_postback, user_id: user.id)
          return
        end

        unless ::UnsubUpdate.unsub_never?(opt)
          Rails.logger.warn("[unsub-update] EMAIL-UNSUB no-op user_id=#{user.id} (digest not set to never)")
          return
        end

        Rails.logger.warn("[unsub-update] EMAIL-UNSUB ENQUEUE user_id=#{user.id}")
        ::Jobs.enqueue(:unsub_update_postback, user_id: user.id)
      rescue => e
        Rails.logger.warn("[unsub-update] EMAIL-UNSUB HOOK ERROR err=#{e.class}: #{e.message}")
        nil
      end
    end

    prepend ::UnsubUpdateEmailUnsubscribeHook
  end

  # -----------------------------
  # 3) UI: ONLY when user actively checks the checkbox,
  #    set dropdown to "never". Do nothing on page load.
  # -----------------------------
  begin
    js_disable_dropdown = ::UnsubUpdateConfig::UI_DISABLE_DIGEST_DROPDOWN_WHEN_UNSUB_ALL ? "true" : "false"

    register_html_builder("server:before-body-close") do |_ctx|
      <<~HTML
        <script>
        (function(){
          try {
            var path = (location && location.pathname) ? location.pathname : "";
            if (path.indexOf("/email/unsubscribe/") !== 0) return;

            var DISABLE = #{js_disable_dropdown};

            function byId(id){ return document.getElementById(id); }

            function setNever(dd){
              if (!dd) return false;
              var v = "0";
              if (dd.value !== v) {
                dd.value = v;
                try { dd.dispatchEvent(new Event("change", {bubbles:true})); } catch(e) {}
                try { dd.dispatchEvent(new Event("input", {bubbles:true})); } catch(e) {}
              }
              return true;
            }

            function bind(){
              var cb = byId("unsubscribe_all");
              var dd = byId("digest_after_minutes");
              if (!dd) return false;

              // page variant without checkbox: nothing to do
              if (!cb) return true;

              if (cb.__unsubUpdateBound) return true;
              cb.__unsubUpdateBound = true;

              cb.addEventListener("change", function(){
                if (cb.checked) {
                  setNever(dd);
                  if (DISABLE) dd.disabled = true;
                } else {
                  if (DISABLE) dd.disabled = false;
                }
              });

              // IMPORTANT: no auto-sync on load
              return true;
            }

            var tries = 0;
            var iv = setInterval(function(){
              tries++;
              if (bind() || tries >= 40) clearInterval(iv);
            }, 100);
          } catch(e) {}
        })();
        </script>
      HTML
    end
  rescue => e
    Rails.logger.warn("[unsub-update] UI inject error err=#{e.class}: #{e.message}")
  end
end
