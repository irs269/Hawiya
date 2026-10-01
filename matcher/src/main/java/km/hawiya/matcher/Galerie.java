package km.hawiya.matcher;

import com.machinezoo.sourceafis.FingerprintMatcher;
import com.machinezoo.sourceafis.FingerprintTemplate;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Base de recherche en mémoire : pour chaque personne, le modèle de chaque doigt
 * (numérotation ISO 1 à 10).
 *
 * Recherche 1:N en force brute, doigt par doigt (on ne compare qu'un index avec
 * des index…). Suffisant pour une démo de quelques milliers de personnes ; pas
 * pour tout le pays (il faudrait un index).
 */
public final class Galerie {

    /** Mode de fusion des scores des doigts d'une même personne. */
    public enum Fusion {
        /** Somme des scores de tous les doigts comparés. */
        SOMME,
        /** Somme des 3 meilleurs scores (tolère un doigt mal capturé). */
        MEILLEURS3
    }

    public record Candidat(String id, double score, Map<Integer, Double> scoresDoigts) {
    }

    private final Map<String, Map<Integer, FingerprintTemplate>> personnes = new ConcurrentHashMap<>();

    public void ajouter(String id, Map<Integer, FingerprintTemplate> doigts) {
        personnes.put(id, Map.copyOf(doigts));
    }

    public boolean retirer(String id) {
        return personnes.remove(id) != null;
    }

    public void vider() {
        personnes.clear();
    }

    public int nombrePersonnes() {
        return personnes.size();
    }

    public int nombreModeles() {
        return personnes.values().stream().mapToInt(Map::size).sum();
    }

    /**
     * Compare les doigts de la sonde à toute la galerie et renvoie les [limite]
     * meilleurs candidats, du plus ressemblant au moins ressemblant.
     */
    public List<Candidat> identifier(Map<Integer, FingerprintTemplate> sonde, Fusion fusion, int limite) {
        // Un comparateur par doigt de la sonde (sa préparation est coûteuse).
        Map<Integer, FingerprintMatcher> comparateurs = new HashMap<>();
        sonde.forEach((doigt, modele) -> comparateurs.put(doigt, new FingerprintMatcher(modele)));

        List<Candidat> candidats = new ArrayList<>();
        personnes.forEach((id, doigts) -> {
            Map<Integer, Double> scores = new HashMap<>();
            comparateurs.forEach((doigt, comparateur) -> {
                FingerprintTemplate candidat = doigts.get(doigt);
                if (candidat != null) {
                    scores.put(doigt, comparateur.match(candidat));
                }
            });
            if (!scores.isEmpty()) {
                candidats.add(new Candidat(id, fusionner(scores, fusion), scores));
            }
        });
        candidats.sort(Comparator.comparingDouble(Candidat::score).reversed());
        return candidats.subList(0, Math.min(limite, candidats.size()));
    }

    static double fusionner(Map<Integer, Double> scores, Fusion fusion) {
        var tries = scores.values().stream().sorted(Comparator.reverseOrder()).toList();
        int n = fusion == Fusion.MEILLEURS3 ? Math.min(3, tries.size()) : tries.size();
        double somme = 0;
        for (int i = 0; i < n; i++) {
            somme += tries.get(i);
        }
        return somme;
    }
}
