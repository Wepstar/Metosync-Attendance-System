// shared.js — one place for Supabase setup and helpers used across every page.
// Fix something here, it's fixed everywhere — no more copy-paste drift.

const SUPABASE_URL = "https://lqgdyjvfirdhstcmepyr.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxxZ2R5anZmaXJkaHN0Y21lcHlyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc1OTAxODQsImV4cCI6MjEwMzE2NjE4NH0.PUvRfQRMKjosn2-LyZWJU1wEOREFJ3jA4Z4TOGxEBA0";

const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

const COUNTRIES = ["Afghanistan","Albania","Algeria","Andorra","Angola","Antigua and Barbuda","Argentina","Armenia","Australia","Austria","Azerbaijan","Bahamas","Bahrain","Bangladesh","Barbados","Belarus","Belgium","Belize","Benin","Bhutan","Bolivia","Bosnia and Herzegovina","Botswana","Brazil","Brunei","Bulgaria","Burkina Faso","Burundi","Cabo Verde","Cambodia","Cameroon","Canada","Central African Republic","Chad","Chile","China","Colombia","Comoros","Congo (Congo-Brazzaville)","Costa Rica","Croatia","Cuba","Cyprus","Czechia","Democratic Republic of the Congo","Denmark","Djibouti","Dominica","Dominican Republic","Ecuador","Egypt","El Salvador","Equatorial Guinea","Eritrea","Estonia","Eswatini","Ethiopia","Fiji","Finland","France","Gabon","Gambia","Georgia","Germany","Ghana","Greece","Grenada","Guatemala","Guinea","Guinea-Bissau","Guyana","Haiti","Honduras","Hungary","Iceland","India","Indonesia","Iran","Iraq","Ireland","Israel","Italy","Ivory Coast","Jamaica","Japan","Jordan","Kazakhstan","Kenya","Kiribati","Kuwait","Kyrgyzstan","Laos","Latvia","Lebanon","Lesotho","Liberia","Libya","Liechtenstein","Lithuania","Luxembourg","Madagascar","Malawi","Malaysia","Maldives","Mali","Malta","Marshall Islands","Mauritania","Mauritius","Mexico","Micronesia","Moldova","Monaco","Mongolia","Montenegro","Morocco","Mozambique","Myanmar","Namibia","Nauru","Nepal","Netherlands","New Zealand","Nicaragua","Niger","Nigeria","North Korea","North Macedonia","Norway","Oman","Pakistan","Palau","Palestine","Panama","Papua New Guinea","Paraguay","Peru","Philippines","Poland","Portugal","Qatar","Romania","Russia","Rwanda","Saint Kitts and Nevis","Saint Lucia","Saint Vincent and the Grenadines","Samoa","San Marino","Sao Tome and Principe","Saudi Arabia","Senegal","Serbia","Seychelles","Sierra Leone","Singapore","Slovakia","Slovenia","Solomon Islands","Somalia","South Africa","South Korea","South Sudan","Spain","Sri Lanka","Sudan","Suriname","Sweden","Switzerland","Syria","Taiwan","Tajikistan","Tanzania","Thailand","Timor-Leste","Togo","Tonga","Trinidad and Tobago","Tunisia","Turkey","Turkmenistan","Tuvalu","Uganda","Ukraine","United Arab Emirates","United Kingdom","United States","Uruguay","Uzbekistan","Vanuatu","Vatican City","Venezuela","Vietnam","Yemen","Zambia","Zimbabwe"];

const CURRENCIES = ["GHS","USD","EUR","GBP","NGN","XOF","CFA","ZAR","KES","CAD"];

function toggleEye(id, btn) {
  const input = document.getElementById(id);
  const showing = input.type === "text";
  input.type = showing ? "password" : "text";
  btn.textContent = showing ? "👁" : "🙈";
}

function waitForInitialSession() {
  // Ask Supabase directly instead of waiting on an onAuthStateChange event —
  // that event (INITIAL_SESSION) isn't guaranteed to fire in every case,
  // and with no timeout/fallback this could hang forever with no error,
  // leaving the page stuck on "Loading..." indefinitely.
  return sb.auth.getSession().then(({ data }) => data.session || null);
}

async function getSessionAndRole() {
  const session = await waitForInitialSession();
    if (!session) return { session: null, isAdmin: false, role: null };

  // Fetch admin status and role concurrently in a single network round-trip
  const [{ data: isAdmin }, { data: role }] = await Promise.all([
    sb.rpc('is_platform_admin'),
    sb.rpc('platform_my_role')
  ]);

  if (!isAdmin) return { session, isAdmin: false, role: null };
  return { session, isAdmin: true, role };
}