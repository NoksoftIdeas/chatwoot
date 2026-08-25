require 'rails_helper'

# Exercises Custom::AgentBuilder through AgentBuilder's public interface, the
# same way spec/enterprise/builders/agent_builder_spec.rb does -- the module is
# prepended by config/initializers/01_inject_enterprise_edition_module.rb, so
# there is nothing to instantiate directly.
RSpec.describe AgentBuilder do
  let(:account) { create(:account) }
  let!(:inviter) { create(:user, account: account, role: 'administrator') }

  def build_for(email)
    described_class.new(
      email: email,
      name: 'Test Agent',
      account: account,
      inviter: inviter
    )
  end

  describe '#perform with the domain allowlist unset' do
    it 'is inert and creates the agent' do
      expect { build_for('anyone@wherever.example').perform }.to change(User, :count).by(1)
    end

    it 'treats an allowlist of only separators and blanks as unset' do
      with_modified_env AGENT_EMAIL_DOMAIN_ALLOWLIST: ' , ,' do
        expect { build_for('anyone@wherever.example').perform }.to change(User, :count).by(1)
      end
    end
  end

  describe '#perform with a domain allowlist' do
    context 'when the email is inside the allowlist' do
      it 'creates the agent' do
        with_modified_env AGENT_EMAIL_DOMAIN_ALLOWLIST: 'noksoft.com' do
          expect { build_for('agent@noksoft.com').perform }.to change(User, :count).by(1)
        end
      end

      it 'delegates to the upstream builder rather than replacing it' do
        user = with_modified_env AGENT_EMAIL_DOMAIN_ALLOWLIST: 'noksoft.com' do
          build_for('agent@noksoft.com').perform
        end

        # These attributes are set by AgentBuilder#perform, so seeing them
        # proves the override called super instead of short-circuiting.
        account_user = AccountUser.find_by(user: user, account: account)
        expect(user.email).to eq('agent@noksoft.com')
        expect(account_user).to be_present
        expect(account_user.role).to eq('agent')
        expect(account_user.inviter).to eq(inviter)
      end

      it 'accepts any of several allowed domains' do
        with_modified_env AGENT_EMAIL_DOMAIN_ALLOWLIST: 'first.com,second.com' do
          expect { build_for('agent@second.com').perform }.to change(User, :count).by(1)
        end
      end

      it 'ignores surrounding whitespace in the allowlist' do
        with_modified_env AGENT_EMAIL_DOMAIN_ALLOWLIST: '  first.com ,  second.com  ' do
          expect { build_for('agent@second.com').perform }.to change(User, :count).by(1)
        end
      end

      it 'matches case-insensitively on both sides' do
        with_modified_env AGENT_EMAIL_DOMAIN_ALLOWLIST: 'NokSoft.COM' do
          expect { build_for('Agent@NOKSOFT.com').perform }.to change(User, :count).by(1)
        end
      end
    end

    context 'when the email is outside the allowlist' do
      it 'raises RecordInvalid' do
        with_modified_env AGENT_EMAIL_DOMAIN_ALLOWLIST: 'noksoft.com' do
          expect { build_for('outsider@gmail.com').perform }.to raise_error(ActiveRecord::RecordInvalid)
        end
      end

      it 'does not create a user or an account user' do
        with_modified_env AGENT_EMAIL_DOMAIN_ALLOWLIST: 'noksoft.com' do
          expect { build_for('outsider@gmail.com').perform }.to raise_error(ActiveRecord::RecordInvalid)
        end

        expect(User.from_email('outsider@gmail.com')).to be_nil
        expect(AccountUser.count).to eq(1) # the inviter only
      end

      it 'names the allowed domains in the error message' do
        with_modified_env AGENT_EMAIL_DOMAIN_ALLOWLIST: 'first.com,second.com' do
          expect { build_for('outsider@gmail.com').perform }
            .to raise_error(ActiveRecord::RecordInvalid, /first\.com, second\.com/)
        end
      end

      it 'rejects a domain that merely ends with an allowed one' do
        # The "@" in the comparison is what stops evil-noksoft.com passing.
        with_modified_env AGENT_EMAIL_DOMAIN_ALLOWLIST: 'noksoft.com' do
          expect { build_for('attacker@evil-noksoft.com').perform }.to raise_error(ActiveRecord::RecordInvalid)
        end
      end

      it 'rejects subdomains of an allowed domain' do
        # Deliberate: the allowlist is an exact domain match. Add the subdomain
        # explicitly if it should be permitted.
        with_modified_env AGENT_EMAIL_DOMAIN_ALLOWLIST: 'noksoft.com' do
          expect { build_for('agent@mail.noksoft.com').perform }.to raise_error(ActiveRecord::RecordInvalid)
        end
      end
    end
  end
end
