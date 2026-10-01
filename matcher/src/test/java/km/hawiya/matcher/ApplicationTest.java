package km.hawiya.matcher;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.javalin.Javalin;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.Base64;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ApplicationTest {

    static final String CLE = "cle-de-test-0123456789"; // valeur de test
    static final ObjectMapper JSON = new ObjectMapper();
    static Javalin app;
    static String base;
    static HttpClient client = HttpClient.newHttpClient();

    @BeforeAll
    static void demarrer() {
        app = Application.creer(new Galerie(), CLE, () -> { }).start(0);
        base = "http://localhost:" + app.port();
    }

    @AfterAll
    static void arreter() {
        app.stop();
    }

    private static HttpResponse<String> appel(String methode, String chemin, Object corps, boolean avecCle) throws Exception {
        var requete = HttpRequest.newBuilder(URI.create(base + chemin))
                .header("Content-Type", "application/json")
                .method(methode, corps == null
                        ? HttpRequest.BodyPublishers.noBody()
                        : HttpRequest.BodyPublishers.ofString(JSON.writeValueAsString(corps)));
        if (avecCle) requete.header(Application.ENTETE_CLE, CLE);
        return client.send(requete.build(), HttpResponse.BodyHandlers.ofString());
    }

    private static String b64(byte[] octets) {
        return Base64.getEncoder().encodeToString(octets);
    }

    @Test
    void santeSansCle() throws Exception {
        var r = appel("GET", "/sante", null, false);
        assertEquals(200, r.statusCode());
        assertTrue(r.body().contains("sourceafis-"));
    }

    @Test
    void refusSansCleOuAvecMauvaiseCle() throws Exception {
        assertEquals(401, appel("POST", "/comparer", java.util.Map.of(), false).statusCode());
        var requete = HttpRequest.newBuilder(URI.create(base + "/comparer"))
                .header(Application.ENTETE_CLE, "mauvaise-cle-mauvaise-cle")
                .POST(HttpRequest.BodyPublishers.ofString("{}")).build();
        assertEquals(401, client.send(requete, HttpResponse.BodyHandlers.ofString()).statusCode());
    }

    @Test
    void cleTropCourteRefuseeAuDemarrage() {
        assertThrows(IllegalStateException.class, () -> Application.creer(new Galerie(), "court", () -> { }));
    }

    @Test
    void parcoursCompletModeleGalerieIdentification() throws Exception {
        byte[] doigt = EmpreinteSynthetique.generer(7);
        // 1. Image PNG → modèle
        var r = appel("POST", "/modeles",
                java.util.Map.of("image", b64(EmpreinteSynthetique.png(doigt)), "dpi", 500), true);
        assertEquals(200, r.statusCode(), r.body());
        String modele = JSON.readTree(r.body()).get("modele").asText();

        // 2. Ajout dans la galerie
        var corpsGalerie = java.util.Map.of("doigts", java.util.List.of(java.util.Map.of("doigt", 2, "modele", modele)));
        assertEquals(204, appel("PUT", "/galerie/C1", corpsGalerie, true).statusCode());

        // 3. Nouvelle capture du même doigt → identifiée
        byte[] capture = EmpreinteSynthetique.transformer(doigt, 5, -8, 6, 3);
        String sonde = b64(EmpreinteSynthetique.modele(capture));
        var demande = java.util.Map.of("doigts", java.util.List.of(java.util.Map.of("doigt", 2, "modele", sonde)));
        JsonNode reponse = JSON.readTree(appel("POST", "/identifier", demande, true).body());
        assertEquals("C1", reponse.get("candidats").get(0).get("id").asText());
        assertTrue(reponse.get("candidats").get(0).get("score").asDouble() > 40);

        // 4. Matrice de scores (outil d'évaluation)
        var matrice = JSON.readTree(appel("POST", "/matrice",
                java.util.Map.of("modeles", java.util.List.of(modele, sonde)), true).body()).get("scores");
        assertEquals(-1, matrice.get(0).get(0).asDouble());
        assertTrue(matrice.get(0).get(1).asDouble() > 40);

        // 5. Retrait
        assertEquals(204, appel("DELETE", "/galerie/C1", null, true).statusCode());
        assertEquals(404, appel("DELETE", "/galerie/C1", null, true).statusCode());
    }

    @Test
    void entreesInvalides() throws Exception {
        assertEquals(400, appel("POST", "/modeles", java.util.Map.of("image", "@@pas-du-base64@@", "dpi", 500), true).statusCode());
        assertEquals(400, appel("POST", "/modeles", java.util.Map.of("image", "AAAA", "dpi", 5), true).statusCode());
        assertEquals(400, appel("POST", "/comparer", java.util.Map.of("sonde", "AAAA", "candidat", "AAAA"), true).statusCode());
        var doigtInvalide = java.util.Map.of("doigts", java.util.List.of(java.util.Map.of("doigt", 11, "modele", "AAAA")));
        assertEquals(400, appel("POST", "/identifier", doigtInvalide, true).statusCode());
    }
}
